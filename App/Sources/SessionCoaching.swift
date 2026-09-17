import Foundation
import ShotGeometry

// MARK: - Evidence grading

/// How much weight a sentence is allowed to carry, from `docs/research/healthy-shot-model-2026-09-14.md` §0.
///
/// The grade travels with every line and every profile row, and it is the **first** sort key for
/// "what to work on": a weak effect on grade-A evidence outranks a strong effect on grade-C lore.
enum EvidenceGrade: Int, Sendable, Comparable, CaseIterable {
    /// Peer-reviewed measurement on skilled shooters, large-n tracking of professionals, or exact geometry.
    case a = 0
    /// Peer-reviewed but small n, recreational population, indirect measure, or internally shaky.
    case b
    /// Expert coaching consensus with a rationale but no controlled measurement.
    case c
    /// Opinion, vendor marketing, or an untested in-house hypothesis.
    case d

    var letter: String {
        switch self {
        case .a: return "A"
        case .b: return "B"
        case .c: return "C"
        case .d: return "D"
        }
    }

    var meaning: String {
        switch self {
        case .a: return "peer-reviewed on skilled shooters, or exact geometry"
        case .b: return "peer-reviewed but small, recreational or indirect"
        case .c: return "coaching consensus, not measured"
        case .d: return "opinion, or an in-house hypothesis not yet tested"
        }
    }

    static func < (l: EvidenceGrade, r: EvidenceGrade) -> Bool { l.rawValue < r.rawValue }
}

// MARK: - Your shot against the published profile

/// "Your shot vs the profile": one row per measure, each carrying what the shooter did, what measured
/// shooters did, the grade of that comparison, and one sentence of reading.
///
/// Rules this struct exists to enforce (brief §6 and `DESIGN-MEMO-2026-09-13.md` §3):
/// - a row is never blank — either `yours` or `unavailableReason` is set;
/// - `profile` is a description of where measured shooters sat, never a target;
/// - `reading` says "associated with", never "because";
/// - below the finding floor the whole table is tagged a preview and no finding is drawn from it.
struct ShotProfile: Sendable {
    struct Row: Identifiable, Sendable {
        var id: Int
        /// The measure's name, in the player's words.
        var metric: String
        /// "7.31 ± 0.37 m/s (n 11)". Nil when it could not be measured — then `unavailableReason` says why.
        var yours: String?
        /// Why the measure is missing, in this block's own terms. Never blank when `yours` is nil.
        var unavailableReason: String?
        /// Where measured shooters sat, with the population named. Not a target.
        var profile: String
        var grade: EvidenceGrade
        /// One sentence. Association language only.
        var reading: String
        /// The paper, dataset or piece of geometry the `profile` column comes from.
        var source: String
    }

    var rows: [Row]
    var accepted: Int
    /// True below the finding floor: the rows may be shown, but nothing may be concluded from them.
    var isPreview: Bool
    /// The tag the UI must print next to a preview table. Nil when the block is at or above the floor.
    var previewTag: String?
    /// The one sentence the table is allowed to say about itself.
    var note: String
}

/// What the block is allowed to say out loud.
///
/// Four parts, each with a rule behind it and its own numbers: what this session says (at most three
/// sentences, every one with ± and n), what to work on (**one** item, and only at n ≥ 30 accepted
/// shots — brief §6: "no finding below 30 shots in the cell. Show 'collecting baseline' and mean
/// it"), how to film next time (derived from what went wrong with this footage, not from taste), and
/// the shot profile (`ShotProfile`, which may show as a preview below the floor).
///
/// Rules of the copy, from `docs/footage-2026-09-13/SHOOTER-REPORT.md` and the brief: "associated
/// with", never "because"; no targets; no score; no adjective that judges the shooter.
struct CoachingCard: Sendable {
    struct Line: Identifiable, Sendable {
        var id: Int
        var text: String
        /// Where the number the sentence leans on comes from, prefixed with its evidence grade so
        /// that a view rendering only `provenance` still shows the grade.
        var provenance: String
        /// The grade of the comparison the sentence makes. Nil for pure instrument reporting.
        var grade: EvidenceGrade?
    }

    enum WorkOn: Sendable {
        /// Below the floor: say how far off it is and what arrives when it is reached.
        case collectingBaseline(accepted: Int, needed: Int)
        /// At or above the floor, one rule fired.
        case finding(title: String, evidence: String, cue: String, provenance: String)
        /// At or above the floor and nothing fired. Saying so is the honest answer.
        case nothingFired(accepted: Int)
    }

    var says: [Line]
    var saysEmptyReason: String?
    var workOn: WorkOn
    var filming: [Line]
    var filmingEmptyReason: String?
    /// "Your shot vs the profile". Always present; `isPreview` is true below the finding floor.
    var profile: ShotProfile
}

enum SessionCoach {
    /// Brief §6: no finding below 30 shots in the cell.
    static let findingMinimumN = 30
    /// The floor for a within-session correlation to be quoted at all. Below this the r is noise.
    static let correlationMinimumN = 15
    /// Ch 5 requires n ≥ 20 before the depth-variance attribution is worth printing.
    static let attributionMinimumN = 20

    // MARK: Published and geometric anchors, each with its grade

    /// Grade A. Skilled shooters' release-speed SD, the same at free-throw and 3-point distance
    /// (Slegers, Lee & Wong 2021, JSSM; n = 12; velocity SD vs 3-pt performance r = −0.96).
    static let skilledSpeedSdRange = 0.05...0.13
    /// Grade A. Skilled shooters' release-angle SD, which was only a weak correlate (same paper).
    static let skilledReleaseAngleSdRange = 1.2...1.3

    /// Grade A. Make rates peak with entry angles in the mid-40s (Daly-Grafstein & Bornn 2019/2020),
    /// and make probability is *flatter* in entry angle than in depth or left-right — so the band is
    /// context, never a target.
    static let entryAngleMakeBand = 43.0...47.0
    /// Below this the block is described as "on the low side" — never as wrong.
    static let entryAngleLowSide = 38.0
    /// Grade A, geometry (`docs/reference/digest-ch15-16-engine.md` §15.1, `flat_arc`):
    /// below 40° the ball's margin through the ring is under 3 cm.
    static let flatArcMean = 40.0

    /// Grade A. NBA 3-pt make probability peaks 10–11 in (0.254–0.279 m) past the front rim; the ring
    /// centre is 9 in (0.229 m). Practice data for youth at this resolution does not exist.
    static let makeDepthBand = 0.254...0.279
    /// Grade A. Noah's "good make zone" is ± 2 in of centre left-to-right; the published signal is the
    /// *variance*, not the mean offset (Slegers & Love 2022: spin-axis SD vs lateral accuracy r = 0.80).
    static let lateralGoodZoneHalfWidth = 0.051

    /// Rule of thumb, free-throw length: 0.1 m/s of release speed moves the crossing about 15 cm.
    /// (Range ≈ v²sin2θ/g, so dRange/dv = 2·Range/v ≈ 1.5 m per m/s at 7.2 m/s over 5.3 m.) Grade A: geometry.
    static let depthCmPerTenthOfAMetrePerSecond = 15.0
    /// A release-speed SD above this fraction of the mean is what the speed rule calls a spread.
    static let speedSpreadFraction = 0.025
    /// A crossing this far from the rim centre counts as long or short (`SHOOTER-REPORT.md` uses 7 cm).
    static let longShortMargin = 0.07
    /// Below this axis ratio the rim's ellipse barely constrains the plane's normal.
    static let thinRimAxisRatio = 0.2
    /// |r| at or above this, at n ≥ `correlationMinimumN`, is worth a sentence — as an observation, not a cause.
    static let correlationWorthReporting = 0.5

    /// Grade B. Peak knee-extension velocity in the preparation, the measure that separated proficient
    /// from non-proficient free-throw shooters: the proficient group moved *slower* into the shot
    /// (Cabarkapa et al. 2023, Front Sports Act Living; n = 34, markerless 120 Hz). Two group means,
    /// not a range and certainly not a target.
    static let proficientKneeExtensionDegreesPerSecond = 212.9
    static let nonProficientKneeExtensionDegreesPerSecond = 269.4

    /// The smallest number of shots with a body-model measure before the card says a sentence about it.
    /// The body model is measured on every shot, accepted or not, so this is its own floor.
    static let bodyMinimumN = 5

    // MARK: - The card

    static func card(summary s: BlockSummary, viewClass: ViewClass?, rimAxisRatio: Double?) -> CoachingCard {
        var says: [(line: CoachingCard.Line, grade: EvidenceGrade, order: Int)] = []
        func say(_ text: String, _ provenance: String, _ grade: EvidenceGrade) {
            says.append((CoachingCard.Line(id: says.count, text: text,
                                           provenance: "grade \(grade.letter) (\(grade.meaning)) — \(provenance)",
                                           grade: grade),
                         grade, says.count))
        }

        // (a) Release-speed consistency, scored in centimetres of depth at the rim. It leads because
        // release-velocity SD is the variable with the strongest published link to shooting performance
        // in the measurement class ArcLab uses, and because centimetres mean something to a shooter.
        if let v = s.releaseSpeed, let sd = v.sd, v.mean > 0 {
            let percent = 100 * sd / v.mean
            let depthCm = sd / 0.1 * depthCmPerTenthOfAMetrePerSecond
            let band = sd <= skilledSpeedSdRange.upperBound
                ? "That sits inside the 0.05–0.13 m/s spread measured in 12 skilled shooters."
                : String(format: "The skilled shooters in that study spread 0.05–0.13 m/s, so this block is %.0f %% wider than the top of their range.",
                         100 * (sd / skilledSpeedSdRange.upperBound - 1))
            say(String(format: "Release speed %.2f ± %.2f m/s (n %d), an SD of %.1f %% of the mean. 0.1 m/s of release speed is associated with about %.0f cm of depth at the rim, so this spread is associated with roughly ± %.0f cm of depth. %@",
                       v.mean, sd, v.n, percent, depthCmPerTenthOfAMetrePerSecond, depthCm, band),
                "measured; the 15 cm per 0.1 m/s figure is the projectile range derivative at this speed; the skilled band is Slegers, Lee & Wong 2021 (n = 12, velocity SD vs 3-pt performance r = −0.96)",
                .a)
        }

        // (b) Where the front-to-back spread comes from. Ch 5 delta method through the rim-crossing
        // Jacobian: this is the sentence that turns a spread into something a shooter can act on.
        if let attribution = depthAttribution(s), attribution.n >= attributionMinimumN {
            let a = attribution.value
            say(String(format: "Front-to-back spread of about %.0f cm (n %d) splits as roughly %.0f %% release speed, %.0f %% release angle and %.0f %% release height, with %.0f %% in how the three move together.",
                       a.sdDepth * 100, attribution.n, a.speedShare * 100, a.thetaShare * 100, a.heightShare * 100, a.covarianceShare * 100),
                "measured; the split is the delta method through the rim-crossing Jacobian evaluated at this block's mean release (textbook Ch 5), not a fitted model",
                .a)
        }

        // (c) What the inferred misses have in common, front to back.
        let missDepths = s.rows.filter { $0.outcome.outcome == .miss }.compactMap(\.depthPastFrontRim)
        if missDepths.count >= 5 {
            let centre = Court.rimInnerDiameter / 2
            let long = missDepths.filter { $0 > centre + longShortMargin }.count
            let short = missDepths.filter { $0 < centre - longShortMargin }.count
            let pattern: String
            if long >= short * 2 && long * 2 >= missDepths.count { pattern = "mostly long" }
            else if short >= long * 2 && short * 2 >= missDepths.count { pattern = "mostly short" }
            else { pattern = "mixed, with no front-to-back pattern" }
            say(String(format: "Of the %d inferred misses with a measured crossing, %d went more than %.0f cm past the rim centre and %d fell more than %.0f cm short: %@. In NBA tracking, make probability peaks 10–11 in past the front rim, so which side the misses sit on is the informative part.",
                       missDepths.count, long, longShortMargin * 100, short, longShortMargin * 100, pattern),
                "measured; outcomes inferred from the ball at the rim; the 10–11 in peak is Daly-Grafstein & Bornn 2019/2020 on >50,000 NBA 3-pt trajectories",
                .a)
        }

        // (d) Entry angle against the published band.
        if let e = s.entryAngleDegrees {
            let tail: String
            if e.mean < entryAngleLowSide {
                tail = "Published make rates peak with entry angles in the mid-40s, so this block is on the low side; below 40° the ball's margin through the ring is under 3 cm, which is geometry rather than a preference."
            } else if entryAngleMakeBand.contains(e.mean) {
                tail = "That is inside the mid-40s band where published make rates peak, though make probability is flatter in entry angle than in depth or left-right."
            } else {
                tail = "Published make rates peak with entry angles in the mid-40s, and make probability is flatter in entry angle than in depth or left-right."
            }
            say(e.sd.map { String(format: "Entry angle %.1f ± %.1f° (n %d). %@", e.mean, $0, e.n, tail) }
                    ?? String(format: "Entry angle %.1f° (n %d, one shot has no spread). %@", e.mean, e.n, tail),
                "measured; the mid-40s band is Daly-Grafstein & Bornn 2019/2020, the 3 cm margin at 40° is ball-and-ring geometry",
                .a)
        }

        // (e) Release angle against this block's own depth-turnover angle. Distance-free and exact:
        // below the turnover, a speed error and an angle error push depth the same way; above it they
        // partly cancel. This is the honest version of "is my arc flat", because it is per shooter.
        if let t = turnover(s) {
            let delta = t.meanReleaseAngleDegrees - t.turnoverDegrees
            let side = delta < 0
                ? "below it, where a speed error and an angle error push the crossing the same way"
                : "above it, where the two partly cancel"
            say(String(format: "Release angle %.1f° against a depth-turnover angle of %.1f° for this block's release height, speed and distance (%.2f m): %+.1f°, %@.",
                       t.meanReleaseAngleDegrees, t.turnoverDegrees, t.distanceMetres, delta, side),
                "measured, then geometry: the turnover is where ∂depth/∂θ changes sign for this block's mean release (ShotGeometry.ReleaseSensitivity). The distance is re-derived from each accepted shot's own fit, so both it and the turnover inherit any scale error in the rim calibration — read the sign of the gap before its size",
                .a)
        }

        // (f) Rhythm and arm extension. The rhythm number comes from the body model's fitted wrist path
        // when there is one (it recovers the dip more often than the 2-D wrist does) and from the 2-D
        // pose otherwise. The **elbow** is now only ever the fitted 3-D value, carrying its own
        // frame-to-frame jitter: the 2-D and 3-D elbows disagreed by up to 50° on the same shot, and
        // only the fitted one held still from shot to shot (PHASE2-PREP, iteration 2).
        let rhythmFromBody = s.bodyDipToReleaseMilliseconds.flatMap { $0.n >= bodyMinimumN ? $0 : nil }
        if viewClass == .side || rhythmFromBody != nil || s.fittedElbowAtReleaseDegrees != nil {
            var parts: [String] = []
            if let b = rhythmFromBody {
                parts.append(b.sd.map { String(format: "rhythm (lowest wrist → release) %.0f ± %.0f ms (n %d)", b.mean, $0, b.n) }
                             ?? String(format: "rhythm %.0f ms (n %d)", b.mean, b.n))
            } else if viewClass == .side, let d = s.dipToReleaseSeconds {
                parts.append(d.sd.map { String(format: "rhythm (lowest wrist → release) %.2f ± %.2f s (n %d)", d.mean, $0, d.n) }
                             ?? String(format: "rhythm %.2f s (n %d)", d.mean, d.n))
            }
            if let e = s.fittedElbowAtReleaseDegrees, e.n >= bodyMinimumN {
                parts.append(e.sd.map { String(format: "the fitted elbow was %.0f ± %.0f° at release (n %d)", e.mean, $0, e.n) }
                             ?? String(format: "the fitted elbow was %.0f° at release (n %d)", e.mean, e.n))
            } else if viewClass == .side, let x = s.elbowMaxNearReleaseDegrees {
                parts.append(x.sd.map { String(format: "the 2-D elbow reached %.0f ± %.0f° near release (n %d)", x.mean, $0, x.n) }
                             ?? String(format: "the 2-D elbow reached %.0f° near release (n %d)", x.mean, x.n))
            }
            if !parts.isEmpty {
                let joined = parts.joined(separator: " and ")
                let caveat = s.fittedElbowJitterDegrees.map {
                    String(format: " The fitted elbow moves %.1f° between sampled frames and a single camera can only bracket an absolute elbow angle to about ±25°, so the spread is the readable part, not the value.", $0)
                } ?? " These are relative numbers, comparable within this camera position and nowhere else."
                say(joined.prefix(1).uppercased() + joined.dropFirst()
                        + ". No published reference range exists for either." + caveat,
                    "measured, relative only; the only published direction is that higher-level U18 players released 12.5 % faster than lower-level (Botsi et al. 2024), which is a group difference, not a range",
                    .a)
            }
        }

        // (f2) Preparatory-phase tempo. Grade B: two group means from one markerless study, so it is
        // reported as where this block sits between them and never as something to move toward.
        if let k = s.kneeExtensionPeakDegreesPerSecond, k.n >= bodyMinimumN {
            let position = k.mean <= proficientKneeExtensionDegreesPerSecond
                ? "at or below the proficient group's mean"
                : (k.mean >= nonProficientKneeExtensionDegreesPerSecond
                   ? "at or above the non-proficient group's mean"
                   : "between the two")
            say(String(format: "The knees extended into the shot at a peak of %.0f%@ °/s (n %d), %@ — the proficient free-throw shooters in the one study that measured this moved slower into the shot (%.0f °/s) than the non-proficient ones (%.0f °/s). That is a group difference between 34 people, not a speed to aim for.",
                       k.mean, k.sd.map { String(format: " ± %.0f", $0) } ?? "", k.n, position,
                       proficientKneeExtensionDegreesPerSecond, nonProficientKneeExtensionDegreesPerSecond),
                "measured from the fitted skeleton's knee angle; the two group means are Cabarkapa et al. 2023, Front Sports Act Living (n = 34, markerless 120 Hz)",
                .b)
        }

        // (g) The in-house hypothesis, tested on this session's own data and labelled as untested.
        // `DESIGN-MEMO-2026-09-13.md` §2.3 proposes rhythm as the coachable proxy for speed consistency.
        // Nothing published supports it, so the app reports the correlation and says exactly that.
        if let r = rhythmVersusSpeed(s) {
            let strength = abs(r.r) >= correlationWorthReporting
                ? (r.r < 0 ? "the longer shots came out slower" : "the longer shots came out faster")
                : "no association strong enough to read anything into"
            say(String(format: "Rhythm time (lowest wrist → release) and release speed moved together at r = %+.2f across %d shots that produced both: %@. This is a within-session association on one block, not evidence that changing the rhythm changes the speed.",
                       r.r, r.n, strength),
                "measured on this block only; the rhythm-to-speed link is an ArcLab hypothesis with no published support, and stays untested for this shooter until it repeats across sessions",
                .d)
        }

        // Grade first, then the order they were authored in. `sort` is not stable in Swift, so the
        // author order is carried explicitly rather than relied on.
        let ordered = says.sorted { ($0.grade.rawValue, $0.order) < ($1.grade.rawValue, $1.order) }
        let shown = Array(ordered.prefix(3)).enumerated().map {
            CoachingCard.Line(id: $0.offset, text: $0.element.line.text,
                              provenance: $0.element.line.provenance, grade: $0.element.grade)
        }
        let emptyReason = shown.isEmpty
            ? (s.accepted == 0 ? "Nothing to say yet: no shot in this block passed the gravity and plausibility gate."
                               : "Nothing to say yet: the accepted shots did not produce a release speed, an entry angle, five inferred misses with a crossing, or side-view pose angles.")
            : nil

        let film = filming(summary: s, rimAxisRatio: rimAxisRatio)
        return CoachingCard(says: shown, saysEmptyReason: emptyReason,
                            workOn: workOn(summary: s),
                            filming: film.enumerated().map {
                                CoachingCard.Line(id: $0.offset, text: $0.element.0, provenance: $0.element.1, grade: nil)
                            },
                            filmingEmptyReason: film.isEmpty
                                ? (s.tracked == 0 ? "Nothing to say yet: no window has been measured."
                                                  : "Nothing to change: the framing, the rim's ellipse and the outcome evidence were all good enough on this clip.")
                                : nil,
                            profile: profile(summary: s, viewClass: viewClass))
    }

    // MARK: - One thing to work on — or an honest count towards it

    /// A rule that fired, with the two keys the queue is ordered by.
    private struct Candidate {
        var grade: EvidenceGrade
        /// How far this block sits from the rule's own anchor, in that anchor's units. **Only a
        /// tie-break inside one grade** — the scales are not comparable between rules, and the copy
        /// never presents this number.
        var effect: Double
        var work: CoachingCard.WorkOn
    }

    static func workOn(summary s: BlockSummary) -> CoachingCard.WorkOn {
        guard s.accepted >= findingMinimumN else {
            return .collectingBaseline(accepted: s.accepted, needed: findingMinimumN)
        }
        var candidates: [Candidate] = []

        // Rule 1 — flat arc. Grade A because the threshold is geometric, not a population average.
        if let e = s.entryAngleDegrees, e.mean < flatArcMean, e.n >= findingMinimumN {
            candidates.append(.init(grade: .a, effect: (flatArcMean - e.mean) / max(e.sd ?? 1, 0.5), work:
                .finding(title: "Entry angle",
                         evidence: e.sd.map { String(format: "Mean entry angle %.1f ± %.1f° over %d accepted shots. Below 40° the ball's margin through the ring is under 3 cm; below 32° a clean swish is geometrically impossible.", e.mean, $0, e.n) }
                             ?? String(format: "Mean entry angle %.1f° over %d accepted shots.", e.mean, e.n),
                         cue: "Shoot so the ball drops through the top of the ring rather than over the front of it.",
                         provenance: "grade A (\(EvidenceGrade.a.meaning)) — published geometry of the rim and ball; make rates peaking in the mid-40s is Daly-Grafstein & Bornn 2019/2020")))
        }

        // Rule 2 — release-speed spread, scored in centimetres of depth rather than in m/s.
        if let v = s.releaseSpeed, let sd = v.sd, v.mean > 0, v.n >= findingMinimumN,
           sd / v.mean >= speedSpreadFraction || sd > skilledSpeedSdRange.upperBound {
            let depthCm = sd / 0.1 * depthCmPerTenthOfAMetrePerSecond
            candidates.append(.init(grade: .a, effect: sd / skilledSpeedSdRange.upperBound, work:
                .finding(title: "Release-speed consistency",
                         evidence: String(format: "Release speed %.2f ± %.2f m/s over %d accepted shots (%.1f %% of the mean), associated with about ± %.0f cm of depth at the rim. Skilled shooters in the one study using this measurement class spread 0.05–0.13 m/s.", v.mean, sd, v.n, 100 * sd / v.mean, depthCm),
                         cue: "Keep the same rhythm from the lowest point of the wrist to the release on every shot.",
                         provenance: "grade A (\(EvidenceGrade.a.meaning)) — Slegers, Lee & Wong 2021, JSSM: release-velocity SD vs 3-pt performance r = −0.96, free-throw r = −0.88 (n = 12). The rhythm cue itself is untested for this shooter: the card reports the within-session correlation rather than assuming it")))
        }

        // Rule 3 — where the front-to-back spread comes from. Fires when the angle channel, not the
        // speed channel, dominates, because the cue differs.
        if let attribution = depthAttribution(s), attribution.n >= attributionMinimumN,
           attribution.value.thetaShare > attribution.value.speedShare, attribution.value.thetaShare > 0.5 {
            let a = attribution.value
            candidates.append(.init(grade: .b, effect: a.thetaShare, work:
                .finding(title: "Release angle is the wider channel",
                         evidence: String(format: "Front-to-back spread of about %.0f cm over %d shots splits as roughly %.0f %% release angle against %.0f %% release speed — the opposite of the usual pattern.", a.sdDepth * 100, attribution.n, a.thetaShare * 100, a.speedShare * 100),
                         cue: "Film the next block from the same side position so the arc is measured the same way, and watch whether the split holds.",
                         provenance: "grade B (\(EvidenceGrade.b.meaning)) — the split itself is exact (delta method, textbook Ch 5), but the claim that an angle-dominant split is worth acting on rests on Slegers 2021 finding angle SD a weak correlate, which is a between-shooter result")))
        }

        // Rule 4 — left-right spread. Published signal is the variance, not the mean offset.
        if let lateral = Stats.summarize(s.rows.filter { $0.verdict.isAccepted }.compactMap(\.lateralDeviation)),
           let sd = lateral.sd, lateral.n >= findingMinimumN, sd > lateralGoodZoneHalfWidth {
            candidates.append(.init(grade: .a, effect: sd / lateralGoodZoneHalfWidth, work:
                .finding(title: "Left-right consistency",
                         evidence: String(format: "Left-right crossing %+.0f ± %.0f cm over %d accepted shots. The published signal is the spread, not the average offset: an average of zero with a wide spread is the pattern that costs makes.", lateral.mean * 100, sd * 100, lateral.n),
                         cue: "Set the camera square to the shot line for the next block so this number is measured rather than inferred.",
                         provenance: "grade A (\(EvidenceGrade.a.meaning)) — Slegers & Love 2022: spin-axis SD vs lateral accuracy r = 0.80 while mean misalignment was not significant; Daly-Grafstein & Bornn 2020: NBA contests raise left-right variance 38 % without biasing direction")))
        }

        // Rule 5 — drift across the session, in release speed.
        if let drift = totalChange(s.rows.filter { $0.verdict.isAccepted }.sorted { $0.id < $1.id }.map(\.releaseSpeed)),
           let v = s.releaseSpeed, let sd = v.sd, abs(drift.change) > 2 * sd, drift.n >= findingMinimumN {
            candidates.append(.init(grade: .a, effect: abs(drift.change) / (2 * sd), work:
                .finding(title: "Drift within the session",
                         evidence: String(format: "Release speed moved %+.2f m/s from the first accepted shot to the last (%d shots, SD %.2f m/s), more than twice the shot-to-shot spread.", drift.change, drift.n, sd),
                         cue: "Note where in the session that happened; a within-session change is usually about fatigue or rhythm, not about the shot itself.",
                         provenance: "grade A (\(EvidenceGrade.a.meaning)) — a least-squares line through shot order. Bourdas et al. 2024 measured entry angle falling 3–4 % and release time rising 15–25 % after a 12-minute simulated game in 38 high-level players; Slawinski et al. 2018 found no change at all in elite U18s, so drift is measured, never assumed")))
        }

        // Rule 6 — the rhythm hypothesis. Grade D, so it can only win when nothing better fired.
        if let r = rhythmVersusSpeed(s), abs(r.r) >= correlationWorthReporting {
            candidates.append(.init(grade: .d, effect: abs(r.r), work:
                .finding(title: "Rhythm and speed moved together",
                         evidence: String(format: "Rhythm time (lowest wrist → release) and release speed correlated r = %+.2f over %d shots that produced both. That is an association inside one session, on one block, and nothing more.", r.r, r.n),
                         cue: "Shoot the next block with the same count in your head and see whether the correlation survives.",
                         provenance: "grade D (\(EvidenceGrade.d.meaning)) — no published study links rhythm-to-release timing SD to release-speed SD. This is ArcLab's own hypothesis (DESIGN-MEMO §2.3) and is listed last on purpose")))
        }

        // Evidence grade first, then the size of the departure inside that grade.
        let best = candidates.sorted { ($0.grade.rawValue, -$0.effect) < ($1.grade.rawValue, -$1.effect) }.first
        return best?.work ?? .nothingFired(accepted: s.accepted)
    }

    // MARK: - Your shot vs the profile

    static func profile(summary s: BlockSummary, viewClass: ViewClass?) -> ShotProfile {
        var rows: [ShotProfile.Row] = []
        func row(_ metric: String, yours: String?, reason: String?, profile: String,
                 grade: EvidenceGrade, reading: String, source: String) {
            rows.append(.init(id: rows.count, metric: metric, yours: yours,
                              unavailableReason: yours == nil ? (reason ?? "not measured on this block") : nil,
                              profile: profile, grade: grade, reading: reading, source: source))
        }

        // 1. Release-speed SD — the strongest published correlate in this measurement class.
        if let v = s.releaseSpeed, let sd = v.sd, v.mean > 0 {
            let depthCm = sd / 0.1 * depthCmPerTenthOfAMetrePerSecond
            row("Release-speed spread",
                yours: String(format: "SD %.2f m/s (%.1f %% of a %.2f m/s mean, n %d) ≈ ± %.0f cm of depth", sd, 100 * sd / v.mean, v.mean, v.n, depthCm),
                reason: nil,
                profile: "0.05–0.13 m/s in 12 skilled shooters, and the same at free-throw and 3-point distance",
                grade: .a,
                reading: sd <= skilledSpeedSdRange.upperBound
                    ? "Inside the spread those shooters showed; this is the channel most strongly associated with shooting percentage, so holding it is worth more than any angle."
                    : "Wider than that band, and the width is associated with depth error at the rim rather than with anything about the arc.",
                source: "Slegers, Lee & Wong 2021, JSSM (n = 12; velocity SD vs 3-pt r = −0.96, FT r = −0.88)")
        } else {
            row("Release-speed spread", yours: nil,
                reason: s.releaseSpeed == nil
                    ? "no accepted shot produced a release speed (\(s.unavailableReason(for: s.releaseSpeed, geometry: true)))"
                    : "one accepted shot has no spread",
                profile: "0.05–0.13 m/s in 12 skilled shooters",
                grade: .a,
                reading: "Nothing to compare until the block has more than one accepted shot with a release.",
                source: "Slegers, Lee & Wong 2021, JSSM")
        }

        // 2. Mean depth past the front rim.
        let acceptedRows = s.rows.filter { $0.verdict.isAccepted }
        if let d = Stats.summarize(acceptedRows.compactMap(\.depthPastFrontRim)) {
            let inBand = makeDepthBand.contains(d.mean)
            row("Depth past the front rim",
                yours: String(format: "%.0f ± %.0f cm (n %d)", d.mean * 100, (d.sd ?? 0) * 100, d.n),
                reason: nil,
                profile: "NBA 3-pt make probability peaks 25–28 cm past the front rim; the ring centre is 22.9 cm",
                grade: .a,
                reading: inBand
                    ? "The average crossing sits where NBA make rates peaked; the spread around it is the part that decides makes."
                    : (d.mean < makeDepthBand.lowerBound
                       ? "The average crossing sits nearer the front of the ring than where NBA make rates peaked, which is the direction contested NBA shots are biased in."
                       : "The average crossing sits deeper than where NBA make rates peaked."),
                source: "Daly-Grafstein & Bornn 2019 JQAS / 2020 JSA (>50,000 NBA 3-pt trajectories)")
        } else {
            row("Depth past the front rim", yours: nil,
                reason: s.unavailableReason(for: s.depthPastFrontRim, geometry: true),
                profile: "peaks 25–28 cm past the front rim in NBA tracking", grade: .a,
                reading: "Nothing to compare until a shot's rim crossing is measured.",
                source: "Daly-Grafstein & Bornn 2019/2020")
        }

        // 3. Left-right spread — variance is the published signal, not the mean.
        if let lateral = Stats.summarize(acceptedRows.compactMap(\.lateralDeviation)), let sd = lateral.sd {
            row("Left-right spread",
                yours: String(format: "%+.0f ± %.0f cm (n %d)", lateral.mean * 100, sd * 100, lateral.n),
                reason: nil,
                profile: "mean offset ≈ 0; what predicts accuracy is the spread, not the average side",
                grade: .a,
                reading: viewClass == .side
                    ? "From a side view this is inferred rather than seen, so read it as the weakest number on this table."
                    : "The average side is not the signal; the width is.",
                source: "Slegers & Love 2022 (spin-axis SD vs lateral accuracy r = 0.80, mean misalignment n.s.); Daly-Grafstein & Bornn 2020")
        } else {
            row("Left-right spread", yours: nil,
                reason: viewClass == .side
                    ? "a side view does not constrain left-right; film from the 45° or frontal position to measure it"
                    : "no accepted shot produced a left-right crossing",
                profile: "mean ≈ 0, and the spread is the signal", grade: .a,
                reading: "Not measurable from this camera position.",
                source: "Slegers & Love 2022")
        }

        // 4. Entry angle.
        if let e = s.entryAngleDegrees {
            row("Entry angle",
                yours: e.sd.map { String(format: "%.1f ± %.1f° (n %d)", e.mean, $0, e.n) }
                    ?? String(format: "%.1f° (n %d, one shot has no spread)", e.mean, e.n),
                reason: nil,
                profile: "NBA makes cluster in the mid-40s; ≥ 32.06° is required for a clean pass at all, and ≥ 40° for a 3 cm margin",
                grade: .a,
                reading: e.mean < flatArcMean
                    ? "Below 40° the ball's margin through the ring is under 3 cm — that part is ball-and-ring geometry, not a preference."
                    : (entryAngleMakeBand.contains(e.mean)
                       ? "Inside the band where NBA make rates peaked, though make probability is flatter in entry angle than in depth or left-right."
                       : "Outside the mid-40s band, which is context rather than a target: make probability changes slowly with entry angle."),
                source: "Daly-Grafstein & Bornn 2019/2020; the 32.06° floor is asin(ball ÷ ring)")
        } else {
            row("Entry angle", yours: nil, reason: s.unavailableReason(for: s.entryAngleDegrees, geometry: true),
                profile: "NBA makes cluster in the mid-40s; 32.06° is the geometric floor", grade: .a,
                reading: "Nothing to compare until a rim crossing is measured.",
                source: "Daly-Grafstein & Bornn 2019/2020")
        }

        // 5. Release angle against this block's own depth-turnover angle — geometry, and distance-free.
        if let t = turnover(s) {
            let delta = t.meanReleaseAngleDegrees - t.turnoverDegrees
            row("Release angle vs your own turnover angle",
                yours: String(format: "%.1f° against a turnover of %.1f° (%+.1f°, n %d)", t.meanReleaseAngleDegrees, t.turnoverDegrees, delta, t.n),
                reason: nil,
                profile: "no universal release angle exists; each shooter's optimum sat 4.3 ± 2.1° above their own minimum-speed angle and tracked their own error covariance (r = 0.78)",
                grade: .a,
                reading: delta < 0
                    ? "Below the turnover, a speed error and an angle error move the crossing the same way, so the two spreads add rather than cancel."
                    : "Above the turnover, a speed error and an angle error partly cancel at the rim.",
                source: "geometry (ShotGeometry.ReleaseSensitivity, ∂depth/∂θ = 0); Slegers 2022, IJPAS for the individuality of the optimum. The distance is re-derived from each shot's own fit and so carries the calibration's scale error: the sign of the gap is more trustworthy than its size")
        } else {
            row("Release angle vs your own turnover angle", yours: nil,
                reason: "this needs release angle, height, speed and the shot distance together on the same accepted shot",
                profile: "each shooter's optimum sat 4.3 ± 2.1° above their own minimum-speed angle", grade: .a,
                reading: "Nothing to compare until an accepted shot carries a full release.",
                source: "Slegers 2022, IJPAS")
        }

        // 6. Release angle against the published distance pattern.
        if let a = s.releaseAngleDegrees, let t = turnover(s) {
            row("Release angle for this distance",
                yours: a.sd.map { String(format: "%.1f ± %.1f° at about %.2f m (n %d)", a.mean, $0, t.distanceMetres, a.n) }
                    ?? String(format: "%.1f° at about %.2f m (n %d)", a.mean, t.distanceMetres, a.n),
                reason: nil,
                profile: "52–55° at 2.7–4.6 m and 48–50° at 6.4 m in 15 males; professionals 60.8 ± 6.3° free throw, 58.9 ± 7.4° 2-pt, 56.9 ± 8.5° 3-pt",
                grade: .b,
                reading: "Release angle falls as distance rises in every study that measured it, so this number only means anything next to the distance it was shot from — never next to another spot's.",
                source: "Miller & Bartlett 1996 (n = 15); Cabarkapa et al. 2022, JFMK (n = 10 professionals, who showed no kinematic difference between excellent and good shooters). The distance is reconstructed from the shots' own fits, not measured, and inherits the calibration's scale error")
        }

        // 7. Release height — the literature gives no direction, and the table has to say so.
        if let h = s.releaseHeight {
            row("Release height",
                yours: h.sd.map { String(format: "%.2f ± %.2f m (n %d)", h.mean, $0, h.n) }
                    ?? String(format: "%.2f m (n %d)", h.mean, h.n),
                reason: nil,
                profile: "2.15–2.47 m across published samples, with the direction of the effect contradictory",
                grade: .b,
                reading: "One study found made free throws released higher, another found missed ones did, and a third found the association negligible — so there is nothing to read into this number beyond its own consistency.",
                source: "Wang et al. 2026; Cabarkapa et al. 2023; Amaro et al. 2025 (ρ = 0.116, η²p < 0.01 over 710 shots)")
        }

        // 8. Dip-to-release timing — consistency only; there is no published range.
        if let d = s.dipToReleaseSeconds, viewClass == .side {
            row("Rhythm: lowest wrist → release",
                yours: d.sd.map { String(format: "%.2f ± %.2f s (n %d)", d.mean, $0, d.n) }
                    ?? String(format: "%.2f s (n %d)", d.mean, d.n),
                reason: nil,
                profile: "no published reference range exists; the only published direction is that higher-level U18 players released 12.5 % faster than lower-level players",
                grade: .a,
                reading: "Only this number's own consistency is readable — there is no range to sit inside, and a faster release is a group difference between levels, not a target.",
                source: "Botsi et al. 2024, JFMK (79 U18 males, t(77) = −3.213, p = 0.002)")
        } else {
            row("Rhythm: lowest wrist → release", yours: nil,
                reason: viewClass == .side ? s.unavailableReason(for: s.dipToReleaseSeconds, geometry: false)
                                           : "the phases are read from a side view; this block was filmed from another angle",
                profile: "no published reference range", grade: .a,
                reading: "Not measurable from this camera position.",
                source: "Botsi et al. 2024, JFMK")
        }

        // 9. Elbow at release — 2-D, side only, and the published definitions disagree.
        if viewClass == .side, let x = s.elbowAtReleaseDegrees {
            row("Elbow at release",
                yours: x.sd.map { String(format: "%.0f ± %.0f° (n %d), 2-D image plane", x.mean, $0, x.n) }
                    ?? String(format: "%.0f° (n %d), 2-D image plane", x.mean, x.n),
                reason: nil,
                profile: "published values disagree by definition: 71.9 ± 5.6° interior angle in proficient free-throw shooters, 158.1 ± 3.1° extension angle on made free throws",
                grade: .b,
                reading: "The two published directions cannot both be compared against a single 2-D angle, so this row is here for its own consistency across sessions filmed from the same spot and for nothing else.",
                source: "Cabarkapa & Fry 2021, CEJSSM (n = 17 recreationally active); Wang et al. 2026 (n = 50, 2-D, uniform effect sizes that warrant caution)")
        } else {
            row("Elbow at release", yours: nil,
                reason: viewClass == .side ? s.unavailableReason(for: s.elbowAtReleaseDegrees, geometry: false)
                                           : "a 2-D elbow angle only means something from a side view",
                profile: "published definitions disagree", grade: .b,
                reading: "Not measurable from this camera position.",
                source: "Cabarkapa & Fry 2021; Wang et al. 2026")
        }

        // 10. Knee flexion minimum — direction only, and the two studies disagree by distance.
        if viewClass == .side, let k = s.kneeMinimumDegrees {
            row("Deepest knee bend",
                yours: k.sd.map { String(format: "%.0f ± %.0f° (n %d), 2-D image plane", k.mean, $0, k.n) }
                    ?? String(format: "%.0f° (n %d), 2-D image plane", k.mean, k.n),
                reason: nil,
                profile: "108.5 ± 9.8° in proficient free-throw shooters vs 117.9 ± 16.3° in non-proficient; at 3-point range the proficient group loaded the other way (113.2° vs 94.3°)",
                grade: .b,
                reading: "The published difference between proficient and non-proficient groups reverses between free-throw and 3-point range, so no direction transfers to one shooter.",
                source: "Cabarkapa & Fry 2021, CEJSSM; Cabarkapa, Cabarkapa & Fry 2026")
        } else {
            row("Deepest knee bend", yours: nil,
                reason: viewClass == .side ? s.unavailableReason(for: s.kneeMinimumDegrees, geometry: false)
                                           : "a 2-D knee angle only means something from a side view",
                profile: "direction differs by distance in the published groups", grade: .b,
                reading: "Not measurable from this camera position.",
                source: "Cabarkapa & Fry 2021; Cabarkapa, Cabarkapa & Fry 2026")
        }

        // 11–14. Measures the body model computes but the block summary does not yet carry. Each is a
        // nil-with-reason row naming the field that would unlock it, per
        // `docs/research/healthy-shot-model-2026-09-14.md` §7.
        //
        // Head stability, from `HeadMetrics.stabilityPx`. Reported divided by the shooter's own
        // ankle-to-nose pixel span: the raw pixel number is camera-position dependent, the ratio is not.
        if let h = s.headStabilityNormalised {
            row("Head stability, lowest wrist → release",
                yours: h.sd.map { String(format: "%.4f ± %.4f of your own height (n %d)", h.mean, $0, h.n) }
                    ?? String(format: "%.4f of your own height (n %d, one shot has no spread)", h.mean, h.n),
                reason: nil,
                profile: "no published range; head and eye stabilisation on target discriminated successful from failed shots and experts from beginners",
                grade: .b,
                reading: "RMS movement of the nose between the dip and the release, divided by your ankle-to-nose pixel span so it still means the same thing after the camera moves. Read your own spread across shots; there is no number to reach.",
                source: "Ripoll et al. 1986, Human Movement Science")
        } else {
            row("Head stability, lowest wrist → release", yours: nil,
                reason: s.bodyUnavailableReason(for: s.headStabilityNormalised),
                profile: "no published range; head and eye stabilisation on target discriminated successful from failed shots and experts from beginners",
                grade: .b,
                reading: "Only ever this shooter's own spread — a head-movement number has no published range to sit against.",
                source: "Ripoll et al. 1986, Human Movement Science")
        }

        // Squareness. `BlockRow.shoulderLineYawDegrees` is carried, but the body model refuses it on a
        // near-side view: the shoulder line projects to 8–13 % of the ankle-to-nose span there, against
        // the 27 % an adult's shows facing the camera, so its depth is not observable and the model
        // returns the measured sentence instead of a number (PHASE2-PREP, iteration 2).
        let yaws = s.rows.compactMap(\.shoulderLineYawDegrees)
        if let y = Stats.summarize(yaws) {
            row("Squareness (shoulder line)",
                yours: y.text(unit: "° of yaw", decimals: 1),
                reason: nil,
                profile: "no published range exists for squareness at all",
                grade: .c,
                reading: "This is coaching consensus, not a measured range, so it can only be read as your own consistency from shot to shot.",
                source: "Knudson 1993, JOPERD (teaching points, not measurement)")
        } else {
            let why = s.rows.compactMap { $0.bodyUnavailableReason }.first
            row("Squareness (shoulder line)", yours: nil,
                reason: why ?? "the body model refused the shoulder line's yaw on this camera position: from near the side the line points along the view ray, so its depth — and therefore the yaw — is not observable, and a number would be invented rather than measured",
                profile: "no published range exists for squareness at all",
                grade: .c,
                reading: "A camera in front of the shooter, or at 45°, is what would make this measurable; from the side it cannot be seen at all.",
                source: "Knudson 1993, JOPERD (teaching points, not measurement)")
        }

        // Kinetic-chain order, from `KineticChain.proximalToDistal`. The **pattern** only: the lags in
        // milliseconds have no published reference range, and on this footage several of them sit at
        // the one-frame floor, which is the resolution of the video rather than a measurement.
        if let p = s.proximalToDistal {
            let floor = s.chainFrameFloorMilliseconds.map { String(format: " One sampled frame is %.0f ms of real time, which is the floor under every gap in the sequence.", $0) } ?? ""
            row("Kinetic-chain order",
                yours: String(format: "knee → hip → shoulder → elbow → wrist on %d of %d shots with a sequence", p.yes, p.n),
                reason: nil,
                profile: "collegiate players showed proximal-dominant shoulder-to-elbow coupling where recreational players showed distal-dominant or simultaneous coupling",
                grade: .b,
                reading: "Only the order is reported; the gap in milliseconds has no reference range and is not shown as a number." + floor,
                source: "Jiang et al. 2025, J Hum Kinet (n = 20, 240 Hz, 3 shots per distance)")
        } else {
            row("Kinetic-chain order", yours: nil,
                reason: s.rows.compactMap { $0.bodyUnavailableReason }.first
                    ?? "no shot produced a sequence of peak extension velocities; each shot's body card says which joints were missing",
                profile: "collegiate players showed proximal-dominant shoulder-to-elbow coupling where recreational players showed distal-dominant or simultaneous coupling",
                grade: .b,
                reading: "Only the order is publishable; the lag in milliseconds has no reference range and will not be shown as a number.",
                source: "Jiang et al. 2025, J Hum Kinet (n = 20, 240 Hz, 3 shots per distance)")
        }

        // Preparation speed, from `KineticChainEvent.peakRateDegreesPerSecond` on the knee.
        if let k = s.kneeExtensionPeakDegreesPerSecond {
            let where_ = k.mean <= proficientKneeExtensionDegreesPerSecond
                ? "at or below the speed the proficient group moved at"
                : (k.mean >= nonProficientKneeExtensionDegreesPerSecond
                   ? "at or above the speed the non-proficient group moved at"
                   : "between the two published group means")
            row("Preparation speed (knee extension)",
                yours: k.text(unit: "°/s", decimals: 0),
                reason: nil,
                profile: String(format: "proficient free-throw shooters moved slower into the shot: knee peak %.1f °/s vs %.1f °/s, centre-of-mass peak 0.87 m/s vs 1.07 m/s",
                                proficientKneeExtensionDegreesPerSecond, nonProficientKneeExtensionDegreesPerSecond),
                grade: .b,
                reading: "This block sits \(where_). The published difference between proficient and non-proficient shooters sat in the preparation, not at release — which is the half of the shot most video apps ignore. It is a group difference, not a target.",
                source: "Cabarkapa et al. 2023, Front Sports Act Living (n = 34, markerless 120 Hz)")
        } else {
            row("Preparation speed (knee extension)", yours: nil,
                reason: s.bodyUnavailableReason(for: s.kneeExtensionPeakDegreesPerSecond),
                profile: "proficient free-throw shooters moved slower into the shot: knee peak 212.9 °/s vs 269.4 °/s, centre-of-mass peak 0.87 m/s vs 1.07 m/s",
                grade: .b,
                reading: "The published difference between proficient and non-proficient shooters sat in the preparation, not at release — which is the half of the shot most video apps ignore.",
                source: "Cabarkapa et al. 2023, Front Sports Act Living (n = 34, markerless 120 Hz)")
        }

        // Elbow at release, the fitted 3-D value, with its jitter said out loud. The 2-D row above it
        // stays: the two disagree by up to 50° on the same shot, and only the fitted one is stable
        // from shot to shot (1.4–1.6°/frame against Vision's 2.4–8.8°).
        if let e = s.fittedElbowAtReleaseDegrees {
            let jitter = s.fittedElbowJitterDegrees.map { String(format: " The fit moves %.1f° between sampled frames, so a change smaller than about %.0f° is not readable.", $0, 2 * $0) } ?? ""
            row("Elbow at release (fitted 3-D)",
                yours: e.text(unit: "°", decimals: 0),
                reason: nil,
                profile: "no healthy range exists; the published work reports within-shooter consistency, not a value",
                grade: .b,
                reading: "One skeleton is fitted to the whole shot and read at the release. A single camera can only bracket an absolute elbow angle to about ±25°, so this is your own shot-to-shot number and not comparable with anyone else's." + jitter,
                source: "Cabarkapa, Cabarkapa & Fry 2026; the ±25° bracket is this app's own measurement against a second pose model")
        } else {
            row("Elbow at release (fitted 3-D)", yours: nil,
                reason: s.bodyUnavailableReason(for: s.fittedElbowAtReleaseDegrees),
                profile: "no healthy range exists; the published work reports within-shooter consistency, not a value",
                grade: .b,
                reading: "Only within-shooter consistency is publishable for an elbow angle, whichever way it is measured.",
                source: "Cabarkapa, Cabarkapa & Fry 2026")
        }

        // 15. Versatility — deliberately a nil row: one block cannot answer it.
        row("Spread stability across spots and sessions", yours: nil,
            reason: "this card sees one block; the comparison needs at least two comparable cells or two sessions",
            profile: "skilled shooters' release-speed SD was the same at free-throw and 3-point distance, and a simulated defender and 105 dBA crowd noise changed nothing in national-level players' release parameters (all p ≥ 0.092, η²p ≤ 0.004)",
            grade: .a,
            reading: "The defensible meaning of a versatile shot is that the spread does not widen when the distance or the condition changes — which is a question about several blocks, not this one.",
            source: "Slegers, Lee & Wong 2021; Amaro et al. 2025, JFMK (n = 18 national-level, 90 shots each); Daly-Grafstein & Bornn 2020 for the +56 % depth variance under NBA contests")

        let preview = s.accepted < findingMinimumN
        return ShotProfile(
            rows: rows,
            accepted: s.accepted,
            isPreview: preview,
            previewTag: preview ? "preview, n < \(findingMinimumN)" : nil,
            note: preview
                ? "These rows describe \(s.accepted) accepted shot\(s.accepted == 1 ? "" : "s"), below the \(findingMinimumN) this app needs before it draws a finding. Read them as a preview of the instrument, not as a verdict. Every range in the right-hand column is where measured shooters sat, never where you should sit."
                : "Every range in the right-hand column is where measured shooters sat, never where you should sit; individual optima differ by construction, and excellent and good professionals showed no kinematic differences at all.")
    }

    // MARK: - Derived quantities

    /// Total change across the session from a least-squares line through shot order: `slope × (n − 1)`.
    static func totalChange(_ values: [Double?]) -> (change: Double, n: Int)? {
        let pairs = values.enumerated().compactMap { i, v in v.map { (Double(i), $0) } }
        guard pairs.count >= 3 else { return nil }
        let n = Double(pairs.count)
        let mx = pairs.map(\.0).reduce(0, +) / n, my = pairs.map(\.1).reduce(0, +) / n
        let sxx = pairs.map { ($0.0 - mx) * ($0.0 - mx) }.reduce(0, +)
        guard sxx > 0 else { return nil }
        let sxy = pairs.map { ($0.0 - mx) * ($0.1 - my) }.reduce(0, +)
        return (sxy / sxx * (pairs.map(\.0).max()! - pairs.map(\.0).min()!), pairs.count)
    }

    /// Pearson r. Nil when either series is constant or the pairs are too few to mean anything.
    static func correlation(_ pairs: [(Double, Double)]) -> Double? {
        guard pairs.count >= 3 else { return nil }
        let n = Double(pairs.count)
        let mx = pairs.map(\.0).reduce(0, +) / n, my = pairs.map(\.1).reduce(0, +) / n
        let sxx = pairs.map { ($0.0 - mx) * ($0.0 - mx) }.reduce(0, +)
        let syy = pairs.map { ($0.1 - my) * ($0.1 - my) }.reduce(0, +)
        guard sxx > 0, syy > 0 else { return nil }
        let sxy = pairs.map { ($0.0 - mx) * ($0.1 - my) }.reduce(0, +)
        return sxy / (sxx * syy).squareRoot()
    }

    /// The within-session association between dip-to-release timing and release speed.
    ///
    /// `DESIGN-MEMO-2026-09-13.md` §2.3 proposes rhythm as the coachable proxy for speed consistency.
    /// Nothing published supports that link, so the app measures it and labels the result grade D.
    static func rhythmVersusSpeed(_ s: BlockSummary) -> (r: Double, n: Int)? {
        // The body model's dip→release is preferred where it exists: it is read from the fitted wrist
        // path, which recovered the dip on windows where the raw 2-D wrist did not.
        let pairs: [(Double, Double)] = s.rows.compactMap { row in
            guard row.verdict.isAccepted, let v = row.releaseSpeed else { return nil }
            guard let t = row.bodyDipToReleaseMilliseconds.map({ $0 / 1000 }) ?? row.dipToReleaseSeconds else { return nil }
            return (t, v)
        }
        guard pairs.count >= correlationMinimumN, let r = correlation(pairs) else { return nil }
        return (r, pairs.count)
    }

    /// Horizontal distance from the release point to the rim centre, reconstructed from the shot's own
    /// fit: `Physics.forward` returns `depth = x(rim height) − (L − rimInnerRadius)`, so `L` inverts it.
    /// The shot's own fitted `g` is used so the reconstruction is consistent with the depth it inverts.
    ///
    /// `BlockRow.releaseDistance` now carries `ShotMetrics.release?.distance`, which the analyzer knew
    /// exactly, so the reconstruction below is only the fallback for a row saved before that field
    /// existed (or a shot whose release was never solved).
    static func releaseToRimCentreMetres(_ r: BlockRow) -> Double? {
        if let d = r.releaseDistance, d > 0.5, d < 12 { return d }
        guard let degrees = r.releaseAngleDegrees, let v = r.releaseSpeed,
              let h = r.releaseHeight, let depth = r.depthPastFrontRim else { return nil }
        let g = (r.gFit.isFinite && r.gFit > 1) ? r.gFit : Court.g
        let theta = Angle.radians(degrees)
        let vx = v * cos(theta), vy = v * sin(theta)
        let disc = vy * vy - 2 * g * (Court.rimHeight - h)
        guard disc >= 0, vx > 0 else { return nil }
        let t = (vy + disc.squareRoot()) / g
        let L = vx * t - depth + Court.rimInnerRadius
        return (L > 0.5 && L < 12) ? L : nil     // outside this a reconstruction is not a shot distance
    }

    /// The block's mean release angle against the depth-turnover angle for its own mean release.
    static func turnover(_ s: BlockSummary) -> (meanReleaseAngleDegrees: Double, turnoverDegrees: Double,
                                                distanceMetres: Double, n: Int)? {
        let rows = s.rows.filter { $0.verdict.isAccepted }
        let samples: [(Double, Double, Double, Double)] = rows.compactMap { r in
            guard let a = r.releaseAngleDegrees, let v = r.releaseSpeed, let h = r.releaseHeight,
                  let L = releaseToRimCentreMetres(r) else { return nil }
            return (Angle.radians(a), v, h, L)
        }
        guard samples.count >= 3 else { return nil }
        let n = Double(samples.count)
        let theta = samples.map(\.0).reduce(0, +) / n
        let v = samples.map(\.1).reduce(0, +) / n
        let h = samples.map(\.2).reduce(0, +) / n
        let L = samples.map(\.3).reduce(0, +) / n
        guard let turn = ReleaseSensitivity.depthTurnoverAngle(v: v, h: h, L: L) else { return nil }
        return (Angle.degrees(theta), Angle.degrees(turn), L, samples.count)
    }

    /// Where the front-to-back spread comes from: the Ch 5 delta method through the rim-crossing
    /// Jacobian, evaluated at this block's mean release. Exact arithmetic on measured numbers.
    static func depthAttribution(_ s: BlockSummary) -> (value: DepthVarianceAttribution, n: Int)? {
        let samples: [(Double, Double, Double)] = s.rows.compactMap { r in
            guard r.verdict.isAccepted, let a = r.releaseAngleDegrees, let v = r.releaseSpeed,
                  let h = r.releaseHeight, releaseToRimCentreMetres(r) != nil else { return nil }
            return (Angle.radians(a), v, h)
        }
        guard samples.count >= attributionMinimumN, let t = turnover(s) else { return nil }
        let n = Double(samples.count)
        let m = (samples.map(\.0).reduce(0, +) / n, samples.map(\.1).reduce(0, +) / n, samples.map(\.2).reduce(0, +) / n)
        let columns = [samples.map { $0.0 - m.0 }, samples.map { $0.1 - m.1 }, samples.map { $0.2 - m.2 }]
        var covariance = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
        for i in 0..<3 {
            for j in 0..<3 {
                covariance[i][j] = zip(columns[i], columns[j]).map(*).reduce(0, +) / (n - 1)
            }
        }
        guard let sensitivity = ReleaseSensitivity.at(theta: m.0, v: m.1, h: m.2, L: t.distanceMetres),
              let attribution = DepthVarianceAttribution.compute(sensitivity: sensitivity, covariance: covariance)
        else { return nil }
        return (attribution, samples.count)
    }

    // MARK: - How to film next time

    static func filming(summary s: BlockSummary, rimAxisRatio: Double?) -> [(String, String)] {
        var out: [(String, String)] = []
        let clipped = s.rows.filter { ($0.ballTopMarginPx ?? .infinity) <= 0 }.count
        if clipped > 0 {
            out.append(("Leave a metre of sky above the arc — tilt up or step back. On \(clipped) of \(s.tracked) measured shot\(s.tracked == 1 ? "" : "s") the ball's top edge reached the top of the frame, so the apex was not seen and the fit had to work without it.",
                        "measured: the highest tracked ball centre was less than half a ball from the top edge"))
        }
        let labelled = s.makes + s.misses
        if s.unknownOutcomes > labelled && s.tracked > 0 {
            out.append(("Say “make” or “miss” out loud after each shot. \(s.unknownOutcomes) of \(s.tracked) outcomes could not be inferred from the ball alone, which is what the make/miss statistics need.",
                        "measured: the rim-behaviour rule returned unknown"))
        }
        if let ratio = rimAxisRatio, ratio < thinRimAxisRatio {
            out.append((String(format: "Lower the tripod, or move so the ring looks rounder. The rim's ellipse has an axis ratio of %.2f, and below %.2f its normal barely constrains the shot plane.", ratio, thinRimAxisRatio),
                        "measured: RimCalibration.ellipse.axisRatio"))
        }
        // Left-right is the one grade-A metric a side view cannot deliver at all.
        if s.rows.contains(where: { $0.viewClass == .side }),
           s.rows.filter({ $0.verdict.isAccepted }).compactMap(\.lateralDeviation).count * 2 < s.accepted {
            out.append(("Shoot a block from the 45° position as well. Left-right spread is one of the two rim-plane numbers with a large published link to makes, and a side view cannot measure it.",
                        "measured: fewer than half the accepted shots produced a left-right crossing from this camera position"))
        }
        return Array(out.prefix(2))
    }
}
