import Foundation

// MARK: - What the shooter can film
//
// Three clip types, because three different families of evidence need three different camera
// positions. A hypothesis that needs a clip the shooter has not filmed is never scored: it is
// returned with the clip it needs and what to film.

public enum ClipRequirement: String, Sendable, Codable, CaseIterable {
    /// Tripod perpendicular to the shot plane. Arc, release angle/speed/height, entry angle,
    /// crossing depth, dip→release, sagittal joint angles.
    case sideView
    /// Camera behind the shooter, on the shot line. Left/right at the rim, spin axis (with the taped
    /// stripe), frontal forearm deviation, shoulder-line squareness.
    case behindShooter
    /// Close, waist-up, 240 fps. Joint angles, sequencing order, head stability.
    case closeForm

    public var whatToFilm: String {
        switch self {
        case .sideView:
            return "Tripod side-on, perpendicular to the line from you to the rim, whole arc plus the rim in frame."
        case .behindShooter:
            return "One set filmed from directly behind you, on the line to the basket, rim in frame — this is the only view that can see left/right at the rim, the spin axis, and whether your forearm flares out."
        case .closeForm:
            return "One set filmed close and waist-up at the highest frame rate your phone offers, so joints, sequencing and head movement are resolvable."
        }
    }
}

// MARK: - Symptoms

public enum SymptomID: String, Sendable, Codable, CaseIterable {
    case shootingShort, shootingLong, missingLeft, missingRight
    case flatArc, tooMuchArc, inconsistent, noPowerFromDistance
    case rotationDiagonal, hitsBackRim, hitsFrontRim
    case rushed, armHeavy, tiredLate
}

public struct Symptom: Sendable {
    public var id: SymptomID
    /// The complaint in the shooter's own words, as a picker row.
    public var title: String
    /// Deterministic, on-device keyword phrases. No model, no network (CLAUDE.md rule 6).
    /// A multi-word phrase outscores a single word, which is what disambiguates "short" from
    /// "short from three".
    public var keywords: [String]
    /// Mechanical hypotheses, in order of prior plausibility.
    public var hypotheses: [HypothesisID]
    /// What the app should say back before showing any evidence.
    public var restatement: String
}

public struct SymptomMatch: Sendable {
    public var symptom: Symptom
    public var score: Double
    public var matchedPhrases: [String]
}

public enum SymptomLibrary {

    public static let all: [Symptom] = [
        Symptom(id: .shootingShort, title: "My shot keeps being short",
                keywords: ["short", "keeps being short", "coming up short", "falling short", "not getting there",
                           "leaving it short", "dies at the rim", "airball short", "under the rim"],
                hypotheses: [.speedUndershoot, .depthBiasShort, .rangeStrengthLimit, .arcVersusTurnover, .fatigueDrift],
                restatement: "Your misses land in front of where your makes cross."),

        Symptom(id: .shootingLong, title: "My shot keeps being long",
                keywords: ["long", "too long", "over the rim", "past the rim", "overshooting", "too strong",
                           "too much", "shooting it long", "deep"],
                hypotheses: [.depthBiasLong, .speedVariability, .arcVersusTurnover, .withinSessionDrift],
                restatement: "Your misses land past where your makes cross."),

        Symptom(id: .missingLeft, title: "I keep missing left",
                keywords: ["left", "missing left", "pulling it left", "goes left", "drifts left", "off to the left"],
                hypotheses: [.lateralAimBias, .lateralVariability, .spinAxisTilt, .forearmFlare, .shoulderSquareness],
                restatement: "Your misses sit to the left of the rim centre."),

        Symptom(id: .missingRight, title: "I keep missing right",
                keywords: ["right", "missing right", "pushing it right", "goes right", "drifts right", "off to the right"],
                hypotheses: [.lateralAimBias, .lateralVariability, .spinAxisTilt, .forearmFlare, .shoulderSquareness],
                restatement: "Your misses sit to the right of the rim centre."),

        Symptom(id: .flatArc, title: "My shot is flat",
                keywords: ["flat", "flat arc", "no arc", "line drive", "not enough arc", "shooting a rope",
                           "low arc", "hits the front of the rim hard"],
                hypotheses: [.flatArcGeometry, .rangeStrengthLimit, .armDominantDrive, .releaseHeightDrift],
                restatement: "Your ball arrives at a shallow angle, which shrinks the opening it has to fit through."),

        Symptom(id: .tooMuchArc, title: "My shot is too high",
                keywords: ["too high", "too much arc", "rainbow", "moon ball", "high arc", "throwing it up"],
                hypotheses: [.arcVersusTurnover, .speedVariability, .releaseHeightDrift],
                restatement: "Your ball arrives steeply. Steep is rarely the problem by itself — what matters is what it does to your depth spread."),

        Symptom(id: .inconsistent, title: "My shot is inconsistent",
                keywords: ["inconsistent", "not consistent", "all over the place", "different every time",
                           "some go in some dont", "no rhythm", "streaky", "unreliable", "cant repeat"],
                hypotheses: [.speedVariability, .lateralVariability, .withinSessionDrift, .headInstability],
                restatement: "Your shots are not landing in the same place twice."),

        Symptom(id: .noPowerFromDistance, title: "I can't get enough power from distance",
                keywords: ["no power", "not enough power", "enough power", "cant get enough power",
                           "power from distance", "further from the basket", "farther from the basket",
                           "further out", "farther out", "further away", "cant reach", "short from three",
                           "weak from distance", "out of range", "struggle from three", "strength"],
                hypotheses: [.rangeStrengthLimit, .armDominantDrive, .rushedPreparation, .flatArcGeometry, .releaseHeightDrift],
                restatement: "Something changes in your release when you step back, and it changes more than it should."),

        Symptom(id: .rotationDiagonal, title: "The rotation on my shot is diagonal",
                keywords: ["rotation", "diagonal", "side spin", "sidespin", "spin is off", "ball spins sideways",
                           "not straight backspin", "wobbles", "tilted spin", "spinning diagonally"],
                hypotheses: [.spinAxisTilt, .forearmFlare, .shoulderSquareness, .lateralVariability],
                restatement: "Your ball is not leaving with a pure backspin axis."),

        Symptom(id: .hitsBackRim, title: "I keep hitting back rim",
                keywords: ["back rim", "back iron", "hits the back", "off the back", "long off the back"],
                hypotheses: [.depthBiasLong, .speedVariability, .arcVersusTurnover],
                restatement: "You are crossing the rim plane past your makes' band."),

        Symptom(id: .hitsFrontRim, title: "I keep hitting front rim",
                keywords: ["front rim", "front iron", "hits the front", "off the front", "clanks the front"],
                hypotheses: [.depthBiasShort, .speedUndershoot, .flatArcGeometry, .rangeStrengthLimit],
                restatement: "You are crossing the rim plane in front of your makes' band."),

        Symptom(id: .rushed, title: "My shot feels rushed",
                keywords: ["rushed", "rushing", "too quick", "hurried", "no time", "snatching at it", "fast release", "quick"],
                hypotheses: [.rushedPreparation, .speedVariability, .headInstability],
                restatement: "Your preparation is getting shorter."),

        Symptom(id: .armHeavy, title: "It feels like all arm, no legs",
                keywords: ["all arm", "arm shot", "arms only", "no legs", "not using my legs", "arm heavy",
                           "throwing it with my arm", "upper body"],
                hypotheses: [.armDominantDrive, .rangeStrengthLimit, .sequencingDistalDominant, .rushedPreparation],
                restatement: "The speed you need may be coming from the arm alone."),

        Symptom(id: .tiredLate, title: "I fall off late in a session",
                keywords: ["tired", "fatigue", "late in the session", "end of the session", "gets worse",
                           "fall off", "legs go", "dead legs", "after a while"],
                hypotheses: [.fatigueDrift, .withinSessionDrift, .speedVariability],
                restatement: "Something drifts across a session."),
    ]

    public static func symptom(_ id: SymptomID) -> Symptom { all.first { $0.id == id }! }

    /// Deterministic on-device matcher. Lower-cases, strips everything but letters, digits and spaces,
    /// then scores whole-word phrase hits with weight = number of words in the phrase. No ML.
    public static func match(_ text: String) -> [SymptomMatch] {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return [] }
        let haystack = " " + normalized + " "
        var out: [SymptomMatch] = []
        for s in all {
            var score = 0.0
            var hits: [String] = []
            for k in s.keywords {
                let phrase = " " + normalize(k) + " "
                guard haystack.contains(phrase) else { continue }
                score += Double(normalize(k).split(separator: " ").count)
                hits.append(k)
            }
            if score > 0 { out.append(SymptomMatch(symptom: s, score: score, matchedPhrases: hits)) }
        }
        // Ties break on the declaration order of `all`, so the same sentence always gives the same answer.
        let order = Dictionary(uniqueKeysWithValues: all.enumerated().map { ($1.id, $0) })
        out.sort { ($0.score, -Double(order[$1.symptom.id] ?? 0)) > ($1.score, -Double(order[$0.symptom.id] ?? 0)) }
        return out
    }

    static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
        var chars = ""
        for c in lowered {
            if c.isLetter || c.isNumber { chars.append(c) }
            else { chars.append(" ") }
        }
        return chars.split(separator: " ").joined(separator: " ")
    }
}

// MARK: - Hypotheses

public enum HypothesisID: String, Sendable, Codable, CaseIterable {
    case speedUndershoot, speedVariability, rangeStrengthLimit, rushedPreparation, armDominantDrive
    case flatArcGeometry, arcVersusTurnover, releaseHeightDrift
    case lateralAimBias, lateralVariability, spinAxisTilt, forearmFlare, shoulderSquareness
    case withinSessionDrift, fatigueDrift, depthBiasShort, depthBiasLong
    case sequencingDistalDominant, headInstability
}

/// Which number the test reads, and in what scope.
public enum EvidenceMeasure: String, Sendable, Codable {
    case missSpeedVersusMakes            // spot: mean release speed of misses − of makes
    case speedShareOfDepthVariance       // spot: delta-method share
    case speedSDRatioAcrossDistance      // near → far
    case dipToReleaseChangeAcrossDistance
    case kneeDriveChangeAcrossDistance
    case entryAngleMean                  // spot, vs the geometric margin
    case releaseAngleVersusTurnover      // spot, θ̄ − own turnover, and whether the θ·v pair compounds
    case releaseHeightAcrossDistance
    case lateralMean, lateralSD
    case spinAxisTilt, forearmFromVertical, shoulderYawSD, headStability, proximalToDistalRate
    case depthMeanVersusReference
    case depthTrendOverSession, entryTrendOverSession
}

public enum EvidenceDirection: String, Sendable, Codable {
    case below, above, widens, narrows, flat, drifts
}

public enum EvidenceThreshold: Sendable {
    /// A fixed number in the measure's own unit.
    case absolute(Double)
    /// The smallest SD ratio these shot counts can distinguish (`DoctorStats.detectableSDRatio`).
    case detectableSDRatio
    /// Multiples of the measure's own session SD — the stand-in for a reliability SD until the
    /// error budget (Ch 13) supplies one.
    case sdMultiple(Double)
    /// Reported, never scored: the literature gives this measure no direction.
    case descriptiveOnly
}

public struct EvidenceTest: Sendable {
    public var measure: EvidenceMeasure
    public var direction: EvidenceDirection
    public var threshold: EvidenceThreshold
    public var thresholdDescription: String
    /// The shot floor below which this test is not run at all.
    public var minimumN: Int
    public var clip: ClipRequirement
}

public struct Hypothesis: Sendable {
    public var id: HypothesisID
    /// One sentence naming the mechanism, in "associated with" language.
    public var statement: String
    public var grade: ShotEvidenceGrade
    public var source: String
    public var test: EvidenceTest
}

public enum HypothesisLibrary {

    public static let all: [Hypothesis] = [
        Hypothesis(id: .speedUndershoot,
                   statement: "Your misses leave your hand slower than your makes do, and depth follows speed almost one-for-one.",
                   grade: .a,
                   source: "Slegers, Lee & Wong 2021 JSSM (velocity SD r = −0.96 with 3P%); Mullineaux & Uhl 2010 (misses −0.12 ± 0.10 m/s vs swishes −0.02 ± 0.07); depth-per-speed is the exact Jacobian",
                   test: EvidenceTest(measure: .missSpeedVersusMakes, direction: .below, threshold: .sdMultiple(0.5),
                                      thresholdDescription: "misses at least half a make-SD slower than makes",
                                      minimumN: ShotDoctor.ownMakesFloor, clip: .sideView)),

        Hypothesis(id: .speedVariability,
                   statement: "Your front-to-back spread is dominated by how much your release speed varies shot to shot.",
                   grade: .a,
                   source: "Slegers 2021 (speed SD is the strongest correlate); delta-method attribution, textbook Ch 5",
                   test: EvidenceTest(measure: .speedShareOfDepthVariance, direction: .above, threshold: .absolute(0.60),
                                      thresholdDescription: "release speed carries ≥ 60 % of the predicted depth variance",
                                      minimumN: ShotDoctor.attributionFloor, clip: .sideView)),

        Hypothesis(id: .rangeStrengthLimit,
                   statement: "Stepping back costs you control, not just effort: your release-speed spread inflates with distance instead of holding.",
                   grade: .a,
                   source: "Slegers 2021 — skilled velocity SD was the same at free-throw and 3-point range (0.086 vs 0.089 m/s); Okazaki & Rodacki 2012 for the accuracy fall with distance",
                   test: EvidenceTest(measure: .speedSDRatioAcrossDistance, direction: .widens, threshold: .detectableSDRatio,
                                      thresholdDescription: "far-spot speed SD wider than the near spot by more than these counts can see by chance",
                                      minimumN: ShotDoctor.spotFloor, clip: .sideView)),

        Hypothesis(id: .rushedPreparation,
                   statement: "Your preparation shortens when you step back — the part of the shot where proficient and non-proficient shooters actually differ.",
                   grade: .b,
                   source: "Cabarkapa et al. 2023 (proficient shooters move slower and lower in preparation; no release-phase differences); Botsi et al. 2024 (higher-level U18s release 12.5 % faster — the literature pulls both ways, so this is your own trend)",
                   test: EvidenceTest(measure: .dipToReleaseChangeAcrossDistance, direction: .below, threshold: .sdMultiple(1.5),
                                      thresholdDescription: "dip→release at the far spot shorter than the near spot by ≥ 1.5 near-spot SDs",
                                      minimumN: ShotDoctor.spotFloor, clip: .sideView)),

        Hypothesis(id: .armDominantDrive,
                   statement: "The extra speed you need from distance is not coming from the legs — your knee drive barely changes when the distance does.",
                   grade: .b,
                   source: "Cabarkapa et al. 2023 (knee peak angular velocity separates proficient from non-proficient); Okazaki & Rodacki 2012 (no significant ankle/knee/hip change with distance in experts, with compensatory speed increase)",
                   test: EvidenceTest(measure: .kneeDriveChangeAcrossDistance, direction: .flat, threshold: .sdMultiple(0.5),
                                      thresholdDescription: "knee-extension peak rate changes by under half a near-spot SD across distance",
                                      minimumN: ShotDoctor.spotFloor, clip: .closeForm)),

        Hypothesis(id: .flatArcGeometry,
                   statement: "Your ball arrives shallow enough that the ring's effective opening is close to the ball's own width.",
                   grade: .a,
                   source: "Exact geometry: asin(d_ball / d_rim) is the floor for a clean pass — 31.4° for a 0.2385 m ball, 32.1° at the top of the rulebook tolerance; by 40° the margin is under 3 cm. Daly-Grafstein & Bornn 2020 for the entry band being flat over a range",
                   test: EvidenceTest(measure: .entryAngleMean, direction: .below, threshold: .absolute(40),
                                      thresholdDescription: "mean entry angle below 40°, where the margin is under 3 cm",
                                      minimumN: 15, clip: .sideView)),

        Hypothesis(id: .arcVersusTurnover,
                   statement: "Your release angle sits on the side of your own depth-turnover angle where your angle and speed errors add up instead of cancelling.",
                   grade: .a,
                   source: "Geometry, per shot: `ReleaseSensitivity.depthTurnoverAngle`; textbook Ch 5 §5.4 (the pairwise term 2·Jθ·Jv·Cov(θ,v) is helpful only when its sign is negative). Slegers 2022: the individual optimum sits 4.3 ± 2.1° above each shooter's own minimum-speed angle",
                   test: EvidenceTest(measure: .releaseAngleVersusTurnover, direction: .above, threshold: .absolute(0),
                                      thresholdDescription: "the θ–speed pairwise variance term is positive, i.e. the two errors compound",
                                      minimumN: ShotDoctor.attributionFloor, clip: .sideView)),

        Hypothesis(id: .releaseHeightDrift,
                   statement: "Your release height changes with distance. The literature gives release height no agreed direction, so this is reported, not scored.",
                   grade: .b,
                   source: "Contradictory: Wang et al. 2026 (makes higher), Cabarkapa 2023 (misses higher), Amaro et al. 2025 (ρ = 0.116, η²p < 0.01). \"Release as high as possible\" is C at best",
                   test: EvidenceTest(measure: .releaseHeightAcrossDistance, direction: .drifts, threshold: .descriptiveOnly,
                                      thresholdDescription: "no threshold — the literature supplies no direction",
                                      minimumN: ShotDoctor.spotFloor, clip: .sideView)),

        Hypothesis(id: .lateralAimBias,
                   statement: "Your crossings sit consistently to one side of the rim centre.",
                   grade: .a,
                   source: "Daly-Grafstein & Bornn 2019/2020: left-right offset has a mean near zero in professionals and it is the variance, not the mean, that predicts. Ring geometry sets the tolerance exactly",
                   test: EvidenceTest(measure: .lateralMean, direction: .above, threshold: .absolute(0.04),
                                      thresholdDescription: "mean left-right offset more than 4 cm from the rim centre",
                                      minimumN: 15, clip: .behindShooter)),

        Hypothesis(id: .lateralVariability,
                   statement: "Your side-to-side spread, not your aim, is what is costing the makes.",
                   grade: .a,
                   source: "Daly-Grafstein & Bornn 2020: left-right variance predicts; in-game contests raise it 38 % without moving the mean",
                   test: EvidenceTest(measure: .lateralSD, direction: .above, threshold: .absolute(0.09),
                                      thresholdDescription: "left-right SD above 9 cm, where the ring's own half-margin runs out",
                                      minimumN: 15, clip: .behindShooter)),

        Hypothesis(id: .spinAxisTilt,
                   statement: "Your ball leaves with a tilted spin axis rather than pure backspin, which both looks diagonal and pushes the ball sideways off the rim.",
                   grade: .b,
                   source: "Spin-axis consistency correlates r = 0.80 with left-right consistency (healthy-shot model §6 row 4). Measurable from a taped stripe at 120–240 fps: 0.2 rev/s of sidespin shows as ≈ 20° of axis tilt (DESIGN-MEMO §3.7)",
                   test: EvidenceTest(measure: .spinAxisTilt, direction: .above, threshold: .absolute(10),
                                      thresholdDescription: "mean spin axis more than 10° off pure backspin",
                                      minimumN: 10, clip: .behindShooter)),

        Hypothesis(id: .forearmFlare,
                   statement: "Your forearm sits away from vertical in the frontal plane — the one joint difference that separated proficient from non-proficient shooters.",
                   grade: .b,
                   source: "Cabarkapa & Fry 2021 CEJSSM: forearm-from-vertical 7.9 ± 7.2° (proficient) vs 19.8 ± 17.6° (non-proficient), n = 17 recreationally active males, between groups only",
                   test: EvidenceTest(measure: .forearmFromVertical, direction: .above, threshold: .absolute(15),
                                      thresholdDescription: "mean forearm-from-vertical above 15°, between the two published group means",
                                      minimumN: 10, clip: .behindShooter)),

        Hypothesis(id: .shoulderSquareness,
                   statement: "Your shoulder line is not repeating from shot to shot.",
                   grade: .c,
                   source: "There is no published squareness range at all. Only your own consistency is readable, and 3-D yaw from a side view is in ArcLab's noisy class",
                   test: EvidenceTest(measure: .shoulderYawSD, direction: .above, threshold: .descriptiveOnly,
                                      thresholdDescription: "no threshold exists — consistency is reported, never scored",
                                      minimumN: 15, clip: .behindShooter)),

        Hypothesis(id: .withinSessionDrift,
                   statement: "Your crossing depth walks in one direction across the session rather than scattering about a centre.",
                   grade: .a,
                   source: "Textbook Ch 15 §15.3.4 trend_over_session: report the total change across the session, not the slope and not a p-value. That drift happens is established (Bourdas 2024); that it happens to you must be measured",
                   test: EvidenceTest(measure: .depthTrendOverSession, direction: .drifts, threshold: .sdMultiple(1.0),
                                      thresholdDescription: "total change across the session larger than one session SD",
                                      minimumN: 15, clip: .sideView)),

        Hypothesis(id: .fatigueDrift,
                   statement: "Your entry angle falls across the session, the signature measured after simulated game load.",
                   grade: .a,
                   source: "Bourdas et al. 2024: after 12 min of simulated game, entry angle −3.1 to −3.9 %, release time +15–25 %, makes −14 to −19 %. Slawinski et al. 2018 found zero change in elite U18s after sprints — so it is measured, never assumed",
                   test: EvidenceTest(measure: .entryTrendOverSession, direction: .below, threshold: .sdMultiple(1.0),
                                      thresholdDescription: "entry angle falls by more than one session SD across the session",
                                      minimumN: 15, clip: .sideView)),

        Hypothesis(id: .depthBiasShort,
                   statement: "Your whole cloud sits in front of the band where makes peak, so even a well-struck shot has less ring to work with.",
                   grade: .a,
                   source: "Daly-Grafstein & Bornn 2019 JQAS: over 50 000 NBA 3-point trajectories, make probability peaked 25–28 cm (10–11 in) past the front rim; the ring centre is 22.9 cm",
                   test: EvidenceTest(measure: .depthMeanVersusReference, direction: .below, threshold: .absolute(0.05),
                                      thresholdDescription: "mean crossing more than 5 cm in front of the reference band",
                                      minimumN: 15, clip: .sideView)),

        Hypothesis(id: .depthBiasLong,
                   statement: "Your whole cloud sits past the band where makes peak.",
                   grade: .a,
                   source: "Daly-Grafstein & Bornn 2019 JQAS, as above",
                   test: EvidenceTest(measure: .depthMeanVersusReference, direction: .above, threshold: .absolute(0.05),
                                      thresholdDescription: "mean crossing more than 5 cm past the reference band",
                                      minimumN: 15, clip: .sideView)),

        Hypothesis(id: .sequencingDistalDominant,
                   statement: "Your shoulder and elbow straighten together instead of the shoulder leading — the recreational pattern in the coordination literature.",
                   grade: .b,
                   source: "Jiang et al. 2025 J Hum Kinet: collegiate players were proximal-dominant at 3.2 m; recreational players were distal-dominant and collapsed to in-phase at 6.8 m. The pattern is the finding; no published lag in milliseconds exists, so ArcLab never scores one",
                   test: EvidenceTest(measure: .proximalToDistalRate, direction: .below, threshold: .absolute(0.5),
                                      thresholdDescription: "shoulder leads the elbow on fewer than half your shots",
                                      minimumN: 10, clip: .closeForm)),

        Hypothesis(id: .headInstability,
                   statement: "Your head moves more between dip and release than it usually does.",
                   grade: .b,
                   source: "Ripoll et al. 1986: head/eye stabilisation on target discriminates experts from beginners and successful from failed shots. No published pixel or metre range exists, so only your own SD and its trend can be read",
                   test: EvidenceTest(measure: .headStability, direction: .above, threshold: .descriptiveOnly,
                                      thresholdDescription: "no published range — your own value and its trend only",
                                      minimumN: 10, clip: .closeForm)),
    ]

    public static func hypothesis(_ id: HypothesisID) -> Hypothesis { all.first { $0.id == id }! }
}

// MARK: - Evaluating a hypothesis against the shooter's own data

public enum HypothesisVerdict: String, Sendable, Codable {
    /// The test ran and the evidence points the way the hypothesis predicts.
    case supported
    /// The test ran and the evidence does not.
    case notSupported
    /// The measure exists but there are fewer shots than the test's own floor.
    case belowFloor
    /// The measure cannot exist from the clips filmed. Carries the clip to film.
    case needsAnotherClip
    /// The measure could exist from these clips but is missing on every shot.
    case noData
    /// Reported, never scored — the literature supplies no direction.
    case descriptive
}

public struct HypothesisEvaluation: Sendable {
    public var hypothesis: Hypothesis
    public var verdict: HypothesisVerdict
    /// Numbers and n, or the exact reason there are none. Never empty.
    public var evidenceLine: String
    /// Magnitude in the test's own units, for tie-breaking only. Nil when nothing was computed.
    public var effect: Double?
    /// Non-nil when `verdict == .needsAnotherClip`.
    public var filmThis: String?
    public var rank: Int
}

public struct ComplaintAnswer: Sendable {
    public var complaint: String
    public var matches: [SymptomMatch]
    public var symptom: Symptom?
    /// Nil when nothing matched — the app shows the picker instead of guessing.
    public var unmatchedReason: String?
    public var focusSpot: DoctorSpot?
    public var ranked: [HypothesisEvaluation]
    /// The one fix the app is allowed to hand over, from the top supported hypothesis.
    public var plan: FixPackage?
    public var honesty: [String]
}

public enum SymptomEngine {

    /// Free-text or picker entry point. `spot` narrows to one spot; nil lets the engine pick the spot
    /// with the most accepted shots.
    public static func answer(complaint: String, diagnosis: Diagnosis, records: [ShotRecord],
                              spot: DoctorSpot? = nil) -> ComplaintAnswer {
        let matches = SymptomLibrary.match(complaint)
        guard let top = matches.first else {
            return ComplaintAnswer(complaint: complaint, matches: [], symptom: nil,
                                   unmatchedReason: "None of the \(SymptomLibrary.all.count) symptoms this engine knows matched what you typed. Pick one from the list rather than have the app guess.",
                                   focusSpot: nil, ranked: [], plan: nil, honesty: FixLibrary.honestyRules)
        }
        return answer(symptom: top.symptom.id, diagnosis: diagnosis, records: records, spot: spot,
                      complaint: complaint, matches: matches)
    }

    public static func answer(symptom id: SymptomID, diagnosis: Diagnosis, records: [ShotRecord],
                              spot: DoctorSpot? = nil, complaint: String = "",
                              matches: [SymptomMatch] = []) -> ComplaintAnswer {
        let symptom = SymptomLibrary.symptom(id)
        let focus = spot ?? diagnosis.perSpot.max(by: { $0.n < $1.n })?.spot
        var evaluations: [HypothesisEvaluation] = []
        for (prior, hid) in symptom.hypotheses.enumerated() {
            let h = HypothesisLibrary.hypothesis(hid)
            var e = evaluate(h, diagnosis: diagnosis, records: records, focus: focus)
            e.rank = prior
            evaluations.append(e)
        }
        evaluations = rankOrder(evaluations)
        let plan = evaluations.first(where: { $0.verdict == .supported }).map { FixLibrary.package(for: $0.hypothesis.id) }
        var honesty = FixLibrary.honestyRules
        if evaluations.allSatisfy({ $0.verdict != .supported }) {
            honesty.insert("Nothing in your data backs any of the mechanisms behind this complaint yet. That is a real answer, not a failure — the lines below say exactly what is missing.", at: 0)
        }
        return ComplaintAnswer(complaint: complaint.isEmpty ? symptom.title : complaint,
                               matches: matches, symptom: symptom, unmatchedReason: nil,
                               focusSpot: focus, ranked: evaluations, plan: plan, honesty: honesty)
    }

    /// Supported first (grade A before B before C, then prior order, then effect), then the tests that
    /// could not run, then what was ruled out. Nothing is hidden.
    static func rankOrder(_ xs: [HypothesisEvaluation]) -> [HypothesisEvaluation] {
        func bucket(_ v: HypothesisVerdict) -> Int {
            switch v {
            case .supported: return 0
            case .belowFloor: return 1
            case .needsAnotherClip: return 2
            case .noData: return 3
            case .descriptive: return 4
            case .notSupported: return 5
            }
        }
        var sorted = xs.sorted {
            let (ba, bb) = (bucket($0.verdict), bucket($1.verdict))
            if ba != bb { return ba < bb }
            if $0.hypothesis.grade != $1.hypothesis.grade { return $0.hypothesis.grade < $1.hypothesis.grade }
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            return abs($0.effect ?? 0) > abs($1.effect ?? 0)
        }
        for i in sorted.indices { sorted[i].rank = i }
        return sorted
    }

    // MARK: The evidence tests

    static func evaluate(_ h: Hypothesis, diagnosis: Diagnosis, records: [ShotRecord],
                         focus: DoctorSpot?) -> HypothesisEvaluation {
        func result(_ v: HypothesisVerdict, _ line: String, _ effect: Double? = nil) -> HypothesisEvaluation {
            HypothesisEvaluation(hypothesis: h, verdict: v, evidenceLine: line, effect: effect,
                                 filmThis: v == .needsAnotherClip ? h.test.clip.whatToFilm : nil, rank: 0)
        }
        func missing(_ what: String) -> HypothesisEvaluation {
            h.test.clip == .sideView
                ? result(.noData, "No shot carried \(what), so this cannot be tested from what you have filmed.")
                : result(.needsAnotherClip, "\(what.prefix(1).uppercased() + what.dropFirst()) needs a different camera position. \(h.test.clip.whatToFilm)")
        }

        let near = diagnosis.distance.profiles.first
        let far = diagnosis.distance.profiles.last
        let spotDiag = focus.flatMap { diagnosis.spot($0) }
        let spotProfile = focus.flatMap { diagnosis.profile($0) }
        let spotRows = records.filter { $0.accepted && $0.spot == focus }

        switch h.test.measure {

        case .missSpeedVersusMakes:
            guard let d = spotDiag else { return result(.noData, "No spot has accepted shots.") }
            let makeSpeeds = spotRows.filter { $0.outcome == .make }.compactMap(\.releaseSpeed)
            let missSpeeds = spotRows.filter { $0.outcome == .miss }.compactMap(\.releaseSpeed)
            guard let mk = MeanSD.of(makeSpeeds), let ms = MeanSD.of(missSpeeds) else {
                return missing("release speed on both makes and misses at \(d.spot.rawValue)")
            }
            guard mk.n >= h.test.minimumN else {
                return result(.belowFloor, "Only \(mk.n) makes at \(d.spot.rawValue) carried a release speed; this test needs \(h.test.minimumN) before a make centroid means anything.", nil)
            }
            let delta = ms.mean - mk.mean
            let inSD = mk.sd > 1e-9 ? delta / mk.sd : 0
            let cm = d.operatingPoint.map { $0.sensitivity.dDepth_dV * delta * 100 }
            var line = String(format: "At %@ your misses left at %.2f m/s and your makes at %.2f ± %.2f m/s (%d makes, %d misses): %+.2f m/s, %.1f make-SDs",
                              d.spot.rawValue, ms.mean, mk.mean, mk.sd, mk.n, ms.n, delta, inSD)
            if let c = cm { line += String(format: ", worth %+.0f cm of depth at your operating point", c) }
            line += "."
            return result(inSD <= -0.5 ? .supported : .notSupported, line, inSD)

        case .speedShareOfDepthVariance:
            guard let d = spotDiag else { return result(.noData, "No spot has accepted shots.") }
            guard let a = d.attribution else {
                return result(.belowFloor, d.attributionUnavailableReason.map { $0.prefix(1).uppercased() + $0.dropFirst() + "." }
                              ?? "The depth-variance split could not be computed at \(d.spot.rawValue).")
            }
            let share = a.speedShare
            let line = String(format: "At %@ release speed carries %.0f%% of your predicted front-to-back variance, angle %.0f%%, height %.0f%%, and the channels' covariance %+.0f%% (n=%d, and the split carries ±10–15 points at this n).",
                              d.spot.rawValue, share * 100, a.thetaShare * 100, a.heightShare * 100,
                              a.covarianceShare * 100, d.n)
            return result(share >= 0.60 ? .supported : .notSupported, line, share)

        case .speedSDRatioAcrossDistance:
            guard let n0 = near, let f0 = far, n0.spot != f0.spot,
                  let a = n0.releaseSpeed, let b = f0.releaseSpeed, a.sd > 1e-9 else {
                return result(.belowFloor, diagnosis.distance.unavailableReason.map { "Cannot compare distances: \($0)." }
                              ?? "Release speed was not measured at two different spots.")
            }
            let ratio = b.sd / a.sd
            guard let floor = DoctorStats.detectableSDRatio(n: min(a.n, b.n)) else {
                return result(.belowFloor, "Too few shots at one of the spots to compare two spreads.")
            }
            let line = String(format: "Release-speed SD %.2f m/s at %@ (n=%d) → %.2f m/s at %@ (n=%d): %.1f× wider, against a %.2f× floor — the smallest widening these counts could tell from chance. Skilled shooters measured at both ranges had the same SD (0.086 vs 0.089 m/s).",
                              a.sd, n0.spot.rawValue, a.n, b.sd, f0.spot.rawValue, b.n, ratio, floor)
            return result(ratio >= floor ? .supported : .notSupported, line, ratio / floor)

        case .dipToReleaseChangeAcrossDistance:
            guard let n0 = near, let f0 = far, n0.spot != f0.spot,
                  let a = n0.dipToRelease, let b = f0.dipToRelease else {
                return missing("dip→release at two different spots")
            }
            let delta = b.mean - a.mean
            let inSD = a.sd > 1e-9 ? delta / a.sd : 0
            let pct = a.mean > 1e-9 ? delta / a.mean * 100 : 0
            let line = String(format: "Dip→release %.2f ± %.2f s at %@ (n=%d) → %.2f ± %.2f s at %@ (n=%d): %+.2f s, %+.0f%%, %.1f near-spot SDs. There is no published reference range for this timing, so only your own change is readable.",
                              a.mean, a.sd, n0.spot.rawValue, a.n, b.mean, b.sd, f0.spot.rawValue, b.n, delta, pct, inSD)
            return result(inSD <= -1.5 ? .supported : .notSupported, line, inSD)

        case .kneeDriveChangeAcrossDistance:
            let nearKnee = records.filter { $0.accepted && $0.spot == near?.spot }.compactMap(\.kneeExtensionPeakDegreesPerSecond)
            let farKnee = records.filter { $0.accepted && $0.spot == far?.spot }.compactMap(\.kneeExtensionPeakDegreesPerSecond)
            guard let a = MeanSD.of(nearKnee), let b = MeanSD.of(farKnee) else {
                return missing("a knee-extension peak rate")
            }
            let inSD = a.sd > 1e-9 ? (b.mean - a.mean) / a.sd : 0
            let line = String(format: "Knee-extension peak %.0f ± %.0f °/s at %@ (n=%d) → %.0f ± %.0f °/s at %@ (n=%d): %.1f near-spot SDs. Proficient shooters in the literature differ from non-proficient in the preparatory phase, not at release.",
                              a.mean, a.sd, near?.spot.rawValue ?? "near", a.n, b.mean, b.sd, far?.spot.rawValue ?? "far", b.n, inSD)
            return result(abs(inSD) < 0.5 ? .supported : .notSupported, line, -abs(inSD))

        case .entryAngleMean:
            guard let p = spotProfile, let e = p.entryAngle else { return missing("an entry angle") }
            guard e.n >= h.test.minimumN else {
                return result(.belowFloor, "Only \(e.n) shots at \(p.spot.rawValue) carried an entry angle; this test needs \(h.test.minimumN).")
            }
            let deg = Angle.degrees(e.mean), sdDeg = Angle.degrees(e.sd)
            let floorDeg = Angle.degrees(Physics.entryFloor())
            let line = String(format: "Entry angle %.1f ± %.1f° at %@ (n=%d). Below %.2f° a size-7 ball cannot pass an 18-inch ring at all; below 40° the margin is under 3 cm. Entry is the least peaked of the three rim-plane variables, so a number inside the band is not a finding.",
                              deg, sdDeg, p.spot.rawValue, e.n, floorDeg)
            return result(deg < 40 ? .supported : .notSupported, line, 40 - deg)

        case .releaseAngleVersusTurnover:
            guard let d = spotDiag, let op = d.operatingPoint else {
                return result(.noData, spotDiag?.operatingPointUnavailableReason.map { "No operating point at this spot: \($0)." }
                              ?? "No operating point at this spot.")
            }
            let thetas = spotRows.compactMap(\.releaseAngle), speeds = spotRows.compactMap(\.releaseSpeed)
            guard thetas.count >= h.test.minimumN, thetas.count == speeds.count,
                  let covTV = DoctorStats.covariance(thetas, speeds) else {
                return result(.belowFloor, "This needs \(h.test.minimumN) shots with both release angle and speed at \(d.spot.rawValue); there are \(min(thetas.count, speeds.count)).")
            }
            let pairwise = 2 * op.sensitivity.dDepth_dTheta * op.sensitivity.dDepth_dV * covTV
            let turnover = op.turnoverAngle.map(Angle.degrees)
            var line = String(format: "Your mean release angle at %@ is %.1f°", d.spot.rawValue, Angle.degrees(op.theta))
            if let t = turnover {
                line += String(format: ", %+.1f° from your own depth-turnover angle of %.1f°", Angle.degrees(op.theta) - t, t)
            } else {
                line += " (no turnover angle exists at this speed and height — the scan found no sign change)"
            }
            line += String(format: ". Your angle and speed errors %@: the pairwise variance term is %+.4f m² (n=%d).",
                           pairwise > 0 ? "compound" : "partly cancel", pairwise, thetas.count)
            return result(pairwise > 0 ? .supported : .notSupported, line, pairwise * 1000)

        case .releaseHeightAcrossDistance:
            guard let n0 = near, let f0 = far, let a = n0.releaseHeight, let b = f0.releaseHeight else {
                return missing("a release height at two spots")
            }
            let line = String(format: "Release height %.2f ± %.2f m at %@ (n=%d) → %.2f ± %.2f m at %@ (n=%d). Reported only: the published studies disagree on whether a higher release helps, hurts, or does nothing (ρ = 0.116, η²p < 0.01 in the largest of them).",
                              a.mean, a.sd, n0.spot.rawValue, a.n, b.mean, b.sd, f0.spot.rawValue, b.n)
            return result(.descriptive, line, b.mean - a.mean)

        case .lateralMean:
            guard let p = spotProfile, let l = p.lateralDeviation else { return missing("left/right at the rim") }
            guard l.n >= h.test.minimumN else {
                return result(.belowFloor, "Only \(l.n) shots carried left/right at the rim; this test needs \(h.test.minimumN).")
            }
            let line = String(format: "Left-right offset %+.0f ± %.0f cm at %@ (n=%d); the ring leaves the ball's centre %.0f cm of room either side. In professionals the mean offset is near zero and it is the spread that predicts.",
                              l.mean * 100, l.sd * 100, p.spot.rawValue, l.n, ShotDoctor.lateralGeometricTolerance * 100)
            return result(abs(l.mean) > 0.04 ? .supported : .notSupported, line, abs(l.mean))

        case .lateralSD:
            guard let p = spotProfile, let l = p.lateralDeviation else { return missing("left/right at the rim") }
            guard l.n >= h.test.minimumN else {
                return result(.belowFloor, "Only \(l.n) shots carried left/right at the rim; this test needs \(h.test.minimumN).")
            }
            let line = String(format: "Left-right SD %.0f cm at %@ (n=%d) against the ring's %.0f cm half-margin for the ball's centre.",
                              l.sd * 100, p.spot.rawValue, l.n, ShotDoctor.lateralGeometricTolerance * 100)
            return result(l.sd > 0.09 ? .supported : .notSupported, line, l.sd)

        case .spinAxisTilt:
            let tilts = spotRows.compactMap(\.spinAxisTiltDegrees)
            guard let t = MeanSD.of(tilts) else {
                return result(.needsAnotherClip, "Nothing has measured your spin axis yet. Put one strip of tape around the ball's seam and film one set from directly behind you; at 120 fps a 0.2 rev/s sidespin component shows as roughly 20° of axis tilt.")
            }
            guard t.n >= h.test.minimumN else {
                return result(.belowFloor, "Only \(t.n) shots carried a spin axis; this test needs \(h.test.minimumN).")
            }
            let line = String(format: "Spin axis %.0f ± %.0f° off pure backspin (n=%d).", t.mean, t.sd, t.n)
            return result(t.mean > 10 ? .supported : .notSupported, line, t.mean)

        case .forearmFromVertical:
            let vals = spotRows.compactMap(\.forearmFromVerticalDegrees)
            guard let v = MeanSD.of(vals) else { return missing("frontal forearm angle") }
            guard v.n >= h.test.minimumN else {
                return result(.belowFloor, "Only \(v.n) shots carried a frontal forearm angle; this test needs \(h.test.minimumN).")
            }
            let line = String(format: "Forearm %.1f ± %.1f° from vertical in the frontal plane (n=%d); the published groups sat at 7.9 ± 7.2° (proficient) and 19.8 ± 17.6° (non-proficient), between groups, n = 17.",
                              v.mean, v.sd, v.n)
            return result(v.mean > 15 ? .supported : .notSupported, line, v.mean)

        case .shoulderYawSD:
            let vals = spotRows.compactMap(\.shoulderLineYawDegrees)
            guard let v = MeanSD.of(vals) else { return missing("shoulder-line yaw") }
            let line = String(format: "Shoulder-line yaw %.1f ± %.1f° (n=%d). There is no published range to compare that with, so it is only ever read against your own past sessions.", v.mean, v.sd, v.n)
            return result(.descriptive, line, v.sd)

        case .headStability:
            let vals = spotRows.compactMap(\.headStabilityNormalised)
            guard let v = MeanSD.of(vals) else { return missing("head stability") }
            let line = String(format: "Head movement dip→release %.4f ± %.4f of your own body height (n=%d). No published range exists; only your own trend can be read.", v.mean, v.sd, v.n)
            return result(.descriptive, line, v.mean)

        case .proximalToDistalRate:
            let flags = spotRows.compactMap(\.proximalToDistal)
            guard flags.count >= 1 else { return missing("a sequencing order") }
            guard flags.count >= h.test.minimumN else {
                return result(.belowFloor, "Only \(flags.count) shots carried a sequencing order; this test needs \(h.test.minimumN).")
            }
            let rate = Double(flags.filter { $0 }.count) / Double(flags.count)
            let line = String(format: "Your shoulder led your elbow on %.0f%% of %d shots. Collegiate players in the coordination study were proximal-dominant at short range; the pattern is the finding and no lag in milliseconds is ever scored.",
                              rate * 100, flags.count)
            return result(rate < 0.5 ? .supported : .notSupported, line, 0.5 - rate)

        case .depthMeanVersusReference:
            guard let d = spotDiag, let c = d.centroid, let obs = d.observedDepth else {
                return missing("a rim crossing")
            }
            guard obs.n >= h.test.minimumN else {
                return result(.belowFloor, "Only \(obs.n) shots at \(d.spot.rawValue) crossed the rim plane; this test needs \(h.test.minimumN).")
            }
            let delta = obs.mean - c.depth
            let line = String(format: "Your crossings averaged %.0f ± %.0f cm past the front rim at %@ (n=%d), %+.0f cm against %@.",
                              obs.mean * 100, obs.sd * 100, d.spot.rawValue, obs.n, delta * 100, c.sourceSentence)
            let fires = h.test.direction == .below ? delta < -0.05 : delta > 0.05
            return result(fires ? .supported : .notSupported, line, delta)

        case .depthTrendOverSession, .entryTrendOverSession:
            let usingEntry = h.test.measure == .entryTrendOverSession
            var changes: [(String, Double, Double, Int)] = []   // session, total change, sd, n
            for sid in Set(spotRows.map(\.sessionID)).sorted() {
                let rows = spotRows.filter { $0.sessionID == sid }.sorted { $0.sequence < $1.sequence }
                let ys = rows.compactMap { usingEntry ? $0.entryAngle : $0.depthPastFrontRim }
                guard ys.count >= h.test.minimumN, let stat = MeanSD.of(ys),
                      let s = DoctorStats.slope(x: (0..<ys.count).map(Double.init), y: ys) else { continue }
                changes.append((sid, s * Double(ys.count - 1), stat.sd, ys.count))
            }
            guard let worst = changes.max(by: { abs($0.1 / max($0.2, 1e-9)) < abs($1.1 / max($1.2, 1e-9)) }) else {
                return result(.belowFloor, "No session at \(focus?.rawValue ?? "this spot") has \(h.test.minimumN) shots with \(usingEntry ? "an entry angle" : "a crossing depth") to fit a trend through.")
            }
            let inSD = worst.1 / max(worst.2, 1e-9)
            let unit = usingEntry ? "°" : "cm"
            let scale = usingEntry ? 180 / Double.pi : 100.0
            let line = String(format: "Across session %@ your %@ changed by %+.1f %@ end to end (%.1f session SDs, n=%d). Ch 15 reports the total change across the session, never the slope and never a p-value; a real reliability SD from the error budget would be the better yardstick and is not available yet.",
                              worst.0, usingEntry ? "entry angle" : "crossing depth", worst.1 * scale, unit, inSD, worst.3)
            let fires = h.test.direction == .below ? inSD <= -1.0 : abs(inSD) >= 1.0
            return result(fires ? .supported : .notSupported, line, inSD)
        }
    }
}
