import XCTest
@testable import ShotGeometry

/// The shot doctor, driven by the two real sessions filmed on 2026-09-14 (iPhone 14 Pro, 8.7 s/shot).
///
/// Free throws n=35: 7.17 ± 0.18 m/s, 49.9 ± 1.8°, 2.13 ± 0.07 m, entry 38.2 ± 3.0°,
/// crossing 32 ± 17 cm past the front rim, 9 make / 25 miss, dip→release 0.78 ± 0.08 s.
/// Threes n=29: 8.09 ± 0.63 m/s, 48.3 ± 4.6°, 2.34 ± 0.13 m, entry 40.7 ± 2.7°,
/// crossing 33 ± 21 cm, 10 make / 15 miss, dip→release 0.58 ± 0.11 s.
///
/// The fixture reproduces those moments exactly (standardised deterministic normals), so every
/// assertion below is against the shooter's real numbers, not against invented ones.
final class ShotDoctorTests: XCTestCase {

    // MARK: Deterministic fixture

    struct LCG {
        var state: UInt64
        mutating func nextUnit() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
        mutating func normals(_ n: Int) -> [Double] {
            var out: [Double] = []
            while out.count < n {
                let u1 = max(nextUnit(), 1e-12), u2 = nextUnit()
                let r = (-2 * log(u1)).squareRoot()
                out.append(r * cos(2 * .pi * u2))
                if out.count < n { out.append(r * sin(2 * .pi * u2)) }
            }
            return out
        }
    }

    /// Deterministic values with EXACTLY the requested mean and sample SD (ddof = 1).
    static func channel(n: Int, mean: Double, sd: Double, seed: UInt64) -> [Double] {
        var g = LCG(state: seed)
        let raw = g.normals(n)
        let m = raw.reduce(0, +) / Double(n)
        let v = raw.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(n - 1)
        let s = v.squareRoot()
        return raw.map { ($0 - m) / s * sd + mean }
    }

    struct SpotSpec {
        var spot: DoctorSpot
        var n: Int
        var speed: (Double, Double)
        var angleDeg: (Double, Double)
        var height: (Double, Double)
        var entryDeg: (Double, Double)
        var depth: (Double, Double)
        var dip: (Double, Double)
        var distance: Double
        var makes: Int
        var unknown: Int
        var lateral: (Double, Double)?
    }

    static func records(_ spec: SpotSpec, sessionID: String, date: Date, firstID: Int, seed: UInt64) -> [ShotRecord] {
        let v = channel(n: spec.n, mean: spec.speed.0, sd: spec.speed.1, seed: seed)
        let th = channel(n: spec.n, mean: Angle.radians(spec.angleDeg.0), sd: Angle.radians(spec.angleDeg.1), seed: seed &+ 11)
        let h = channel(n: spec.n, mean: spec.height.0, sd: spec.height.1, seed: seed &+ 23)
        let e = channel(n: spec.n, mean: Angle.radians(spec.entryDeg.0), sd: Angle.radians(spec.entryDeg.1), seed: seed &+ 37)
        let d = channel(n: spec.n, mean: spec.depth.0, sd: spec.depth.1, seed: seed &+ 53)
        let dip = channel(n: spec.n, mean: spec.dip.0, sd: spec.dip.1, seed: seed &+ 71)
        let lat = spec.lateral.map { channel(n: spec.n, mean: $0.0, sd: $0.1, seed: seed &+ 97) }

        // Outcomes: the shots that crossed closest to the published make band are the makes, which is
        // both realistic and deterministic. A few are marked "outcome not seen" — the app's honest
        // third state — so the counts are makes + misses + unknown = n.
        let byCloseness = (0..<spec.n).sorted { abs(d[$0] - 0.265) < abs(d[$1] - 0.265) }
        var outcome = [ShotOutcomeLabel](repeating: .miss, count: spec.n)
        for i in 0..<spec.makes { outcome[byCloseness[i]] = .make }
        for k in 0..<spec.unknown { outcome[byCloseness[spec.makes + k]] = .unknown }

        return (0..<spec.n).map { i in
            ShotRecord(id: firstID + i, sessionID: sessionID, sessionDate: date, sequence: i,
                       spot: spec.spot, outcome: outcome[i], accepted: true,
                       releaseSpeed: v[i], releaseAngle: th[i], releaseHeight: h[i],
                       releaseDistance: spec.distance, entryAngle: e[i], depthPastFrontRim: d[i],
                       lateralDeviation: lat?[i], dipToRelease: dip[i], viewClass: .side)
        }
    }

    static let night = Date(timeIntervalSince1970: 1_789_000_000)

    /// Release distances are the lever arm `Physics.forward` needs: they are the values at which the
    /// stated release means reproduce the stated crossing depths (4.13 m and 5.82 m release-point to
    /// rim-centre, i.e. roughly 0.6–0.9 m of step-in from the line and the arc).
    static let freeThrowSpec = SpotSpec(spot: .freeThrow, n: 35, speed: (7.17, 0.18), angleDeg: (49.9, 1.8),
                                        height: (2.13, 0.07), entryDeg: (38.2, 3.0), depth: (0.32, 0.17),
                                        dip: (0.78, 0.08), distance: 4.13, makes: 9, unknown: 1, lateral: nil)
    static let threeSpec = SpotSpec(spot: .three, n: 29, speed: (8.09, 0.63), angleDeg: (48.3, 4.6),
                                    height: (2.34, 0.13), entryDeg: (40.7, 2.7), depth: (0.33, 0.21),
                                    dip: (0.58, 0.11), distance: 5.82, makes: 10, unknown: 4, lateral: nil)

    static var tonight: [ShotRecord] {
        records(freeThrowSpec, sessionID: "2026-09-14-ft", date: night, firstID: 1, seed: 7)
        + records(threeSpec, sessionID: "2026-09-14-three", date: night, firstID: 100, seed: 19)
    }

    // MARK: 1 — the fixture is the real session

    func testFixtureReproducesTonightsMoments() throws {
        let d = ShotDoctor.diagnose(records: Self.tonight)
        let ft = try XCTUnwrap(d.profile(.freeThrow))
        XCTAssertEqual(ft.n, 35)
        XCTAssertEqual(try XCTUnwrap(ft.releaseSpeed).mean, 7.17, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(ft.releaseSpeed).sd, 0.18, accuracy: 1e-9)
        XCTAssertEqual(Angle.degrees(try XCTUnwrap(ft.releaseAngle).sd), 1.8, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(ft.dipToRelease).mean, 0.78, accuracy: 1e-9)
        let three = try XCTUnwrap(d.profile(.three))
        XCTAssertEqual(try XCTUnwrap(three.releaseSpeed).sd, 0.63, accuracy: 1e-9)
        XCTAssertEqual(Angle.degrees(try XCTUnwrap(three.entryAngle).mean), 40.7, accuracy: 1e-9)
        XCTAssertEqual(d.spot(.freeThrow)?.makes, 9)
        XCTAssertEqual(d.spot(.freeThrow)?.misses, 25)
        XCTAssertEqual(d.spot(.three)?.makes, 10)
        XCTAssertEqual(d.spot(.three)?.misses, 15)
    }

    // MARK: 2 — per-shot miss decomposition

    func testMissDecompositionUsesOwnMakesAndConvertsToCentimetresOfDepth() throws {
        let d = ShotDoctor.diagnose(records: Self.tonight)
        let ft = try XCTUnwrap(d.spot(.freeThrow))

        let centroid = try XCTUnwrap(ft.centroid)
        XCTAssertEqual(centroid.source, .ownMakes, "9 makes is at or above the floor of 8")
        XCTAssertEqual(centroid.n, 9)
        XCTAssertNotNil(centroid.speed, "own-makes reference carries the makes' release variables")

        XCTAssertEqual(ft.missDecompositions.count, 25)
        let op = try XCTUnwrap(ft.operatingPoint)
        XCTAssertGreaterThan(op.sensitivity.dDepth_dV, 1.0, "at the free-throw line a m/s is worth more than a metre of depth")
        XCTAssertEqual(op.cmPerTenthOfSpeed, op.sensitivity.dDepth_dV * 10, accuracy: 1e-9)

        for m in ft.missDecompositions {
            XCTAssertFalse(m.sentence.isEmpty)
            XCTAssertEqual(m.contributions.count, 3, "speed, angle and height are all comparable at this spot")
            XCTAssertNotNil(m.unexplainedCm, "the residual is always stated, never hidden")
            // the three channel contributions plus the residual must reconstruct the miss exactly
            let sum = m.contributions.map(\.depthCm).reduce(0, +) + (m.unexplainedCm ?? 0)
            XCTAssertEqual(sum, m.depthErrorCm, accuracy: 1e-6)
            XCTAssertNil(m.lateralErrorCm, "a side view cannot see left/right")
            XCTAssertNotNil(m.lateralUnavailableReason)
            XCTAssertTrue(try XCTUnwrap(m.lateralUnavailableReason).contains("behind the shooter"))
        }

        let shorts = ft.missDecompositions.filter { $0.depthDirection == .short }
        let longs = ft.missDecompositions.filter { $0.depthDirection == .long }
        XCTAssertGreaterThan(shorts.count + longs.count, 0)
        XCTAssertTrue(ft.headline.contains("Free throws"))

        // Speed is the dominant channel of the front-to-back spread at both spots.
        let dominant = try XCTUnwrap(ft.dominantCause)
        XCTAssertEqual(dominant.channel, "release speed")
        XCTAssertGreaterThan(dominant.share, 0.7)
        XCTAssertEqual(dominant.n, 35)
        let threeDominant = try XCTUnwrap(d.spot(.three)?.dominantCause)
        XCTAssertEqual(threeDominant.channel, "release speed")
        XCTAssertGreaterThan(threeDominant.share, 0.9, "0.63 m/s of speed SD swamps everything else at three-point range")

        // The delta method predicts a wider spread than the shots actually showed; that must be said,
        // not papered over.
        XCTAssertTrue(ft.honesty.contains { $0.contains("predicts") && $0.contains("landed in") },
                      "the prediction-vs-observation mismatch is reported: \(ft.honesty)")
    }

    // MARK: 3 — distance dependence and versatility

    func testDistanceDependenceProducesTheTonightStatements() throws {
        let d = ShotDoctor.diagnose(records: Self.tonight)
        let joined = d.distance.statements.joined(separator: "\n")
        XCTAssertTrue(joined.contains("speed SD 0.18 → 0.63"), joined)
        XCTAssertTrue(joined.contains("angle SD 1.8 → 4.6"), joined)
        XCTAssertTrue(joined.contains("dip→release 0.78 → 0.58 s"), joined)
        XCTAssertTrue(joined.contains("n=35"))
        XCTAssertTrue(joined.contains("n=29"))

        let v = d.distance.versatility
        XCTAssertEqual(v.verdict, .spreadWidens)
        XCTAssertEqual(try XCTUnwrap(v.speedSDRatio), 0.63 / 0.18, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(v.detectableRatio), exp(1.96 / 29.0.squareRoot()), accuracy: 1e-9)
        XCTAssertEqual(v.grade, .a)
        XCTAssertEqual(v.nearSpot, .freeThrow)
        XCTAssertEqual(v.farSpot, .three)

        // Every trend carries n per spot and a slope where two distances exist.
        let speedSD = try XCTUnwrap(d.distance.trends.first { $0.label == "release-speed SD" })
        XCTAssertEqual(speedSD.nearN, 35)
        XCTAssertEqual(speedSD.farN, 29)
        XCTAssertNotNil(speedSD.slopePerMetre)
        XCTAssertEqual(try XCTUnwrap(speedSD.ratio), 3.5, accuracy: 1e-9)
        let entry = try XCTUnwrap(d.distance.trends.first { $0.label == "entry angle" })
        XCTAssertEqual(entry.near, 38.2, accuracy: 1e-9)
        XCTAssertEqual(entry.far, 40.7, accuracy: 1e-9)
    }

    /// The memo's detectability table (§3.5) is what the ratio floor has to reproduce.
    func testDetectableSDRatioMatchesTheMemoTable() throws {
        XCTAssertEqual(try XCTUnwrap(DoctorStats.detectableSDRatio(n: 30)), 1.36, accuracy: 0.08)
        XCTAssertEqual(try XCTUnwrap(DoctorStats.detectableSDRatio(n: 50)), 1.28, accuracy: 0.04)
        XCTAssertEqual(try XCTUnwrap(DoctorStats.detectableSDRatio(n: 100)), 1.20, accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(DoctorStats.detectableSDRatio(n: 200)), 1.14, accuracy: 0.01)
        XCTAssertNil(DoctorStats.detectableSDRatio(n: 1))
    }

    // MARK: 4 — the complaint, end to end

    func testNoPowerFromDistanceComplaintRanksRangeStrengthFirstAndHandsBackOneFix() throws {
        let records = Self.tonight
        let d = ShotDoctor.diagnose(records: records)
        let answer = SymptomEngine.answer(complaint: "when i get further from the basket i cant get enough power",
                                          diagnosis: d, records: records)
        XCTAssertNil(answer.unmatchedReason)
        XCTAssertEqual(answer.symptom?.id, .noPowerFromDistance)

        let top = try XCTUnwrap(answer.ranked.first)
        XCTAssertEqual(top.hypothesis.id, .rangeStrengthLimit)
        XCTAssertEqual(top.verdict, .supported)
        XCTAssertEqual(top.hypothesis.grade, .a)
        XCTAssertTrue(top.evidenceLine.contains("0.18"), top.evidenceLine)
        XCTAssertTrue(top.evidenceLine.contains("0.63"), top.evidenceLine)
        XCTAssertTrue(top.evidenceLine.contains("n=35") && top.evidenceLine.contains("n=29"), top.evidenceLine)

        let byID = Dictionary(uniqueKeysWithValues: answer.ranked.map { ($0.hypothesis.id, $0) })

        // Flat arc is a real grade-A geometric finding at the free-throw line tonight (38.2° < 40°).
        XCTAssertEqual(byID[.flatArcGeometry]?.verdict, .supported)
        XCTAssertTrue(try XCTUnwrap(byID[.flatArcGeometry]).evidenceLine.contains("38.2"))

        // The preparation shortens by 2.5 near-spot SDs — supported, but grade B, so it ranks below.
        XCTAssertEqual(byID[.rushedPreparation]?.verdict, .supported)
        XCTAssertEqual(try XCTUnwrap(byID[.rushedPreparation]?.effect), (0.58 - 0.78) / 0.08, accuracy: 1e-9)
        let rushRank = try XCTUnwrap(byID[.rushedPreparation]?.rank)
        XCTAssertGreaterThan(rushRank, top.rank)

        // No knee data was filmed: the hypothesis is neither scored nor silently dropped.
        let knee = try XCTUnwrap(byID[.armDominantDrive])
        XCTAssertEqual(knee.verdict, .needsAnotherClip)
        XCTAssertNotNil(knee.filmThis)
        XCTAssertTrue(try XCTUnwrap(knee.filmThis).contains("waist-up"))

        // Release height is reported, never scored.
        XCTAssertEqual(byID[.releaseHeightDrift]?.verdict, .descriptive)

        // Exactly one fix comes back, and it is the top supported hypothesis'.
        let plan = try XCTUnwrap(answer.plan)
        XCTAssertEqual(plan.hypothesis, .rangeStrengthLimit)
        XCTAssertEqual(plan.drill.totalShots, 80)
        XCTAssertEqual(plan.passCheck.measure, .releaseSpeedSD)
        XCTAssertEqual(plan.passCheck.scope, .farSpot)
        XCTAssertFalse(plan.cue.isEmpty)
        XCTAssertFalse(plan.retentionRule.isEmpty)
        XCTAssertTrue(answer.honesty.contains { $0.contains("One fix at a time") })
        XCTAssertTrue(answer.honesty.contains { $0.contains("associated with") })
        XCTAssertTrue(answer.honesty.contains { $0.contains("shot floor") })
    }

    func testEveryHypothesisHasAFixAndEverySymptomResolves() {
        for id in HypothesisID.allCases {
            let p = FixLibrary.package(for: id)
            XCTAssertFalse(p.cue.isEmpty, "\(id) has no cue")
            XCTAssertFalse(p.source.isEmpty, "\(id) has no source")
            XCTAssertFalse(p.passCheck.description.isEmpty, "\(id) has no pass check")
            XCTAssertFalse(p.retentionRule.isEmpty, "\(id) has no retention rule")
        }
        for s in SymptomLibrary.all {
            XCTAssertFalse(s.hypotheses.isEmpty, "\(s.id) has no hypotheses")
            XCTAssertFalse(s.keywords.isEmpty, "\(s.id) has no keywords")
        }
        // Every hypothesis the library defines is reachable from at least one symptom.
        let reachable = Set(SymptomLibrary.all.flatMap(\.hypotheses))
        for h in HypothesisID.allCases { XCTAssertTrue(reachable.contains(h), "\(h) is unreachable from any symptom") }
    }

    func testMatcherIsDeterministicAndRefusesToGuess() throws {
        XCTAssertEqual(SymptomLibrary.match("my shot keeps being short").first?.symptom.id, .shootingShort)
        XCTAssertEqual(SymptomLibrary.match("The rotation on my shot is diagonal").first?.symptom.id, .rotationDiagonal)
        XCTAssertEqual(SymptomLibrary.match("I keep hitting front rim").first?.symptom.id, .hitsFrontRim)
        XCTAssertEqual(SymptomLibrary.match("everything is all over the place").first?.symptom.id, .inconsistent)
        XCTAssertEqual(SymptomLibrary.match("I fall off late in the session").first?.symptom.id, .tiredLate)
        // Same input, same answer, every time.
        XCTAssertEqual(SymptomLibrary.match("my shot is flat").map(\.symptom.id),
                       SymptomLibrary.match("MY SHOT IS FLAT!!").map(\.symptom.id))
        XCTAssertTrue(SymptomLibrary.match("the weather is nice").isEmpty)

        let d = ShotDoctor.diagnose(records: Self.tonight)
        let answer = SymptomEngine.answer(complaint: "the weather is nice", diagnosis: d, records: Self.tonight)
        XCTAssertNotNil(answer.unmatchedReason)
        XCTAssertNil(answer.plan)
        XCTAssertTrue(answer.ranked.isEmpty)
    }

    // MARK: 5 — nil-with-a-reason paths

    func testTooFewMakesFallsBackToThePublishedBandAndSaysSo() throws {
        var spec = Self.freeThrowSpec
        spec.makes = 3
        spec.unknown = 0
        let rows = Self.records(spec, sessionID: "s", date: Self.night, firstID: 1, seed: 7)
        let ft = try XCTUnwrap(ShotDoctor.diagnose(records: rows).spot(.freeThrow))
        let c = try XCTUnwrap(ft.centroid)
        XCTAssertEqual(c.source, .publishedBand)
        XCTAssertEqual(c.depth, ShotDoctor.publishedMakeDepth, accuracy: 1e-12)
        XCTAssertNil(c.speed, "a published depth says nothing about how this shooter should release")
        XCTAssertTrue(ft.honesty.contains { $0.contains("published 25–28 cm band") }, "\(ft.honesty)")
        XCTAssertTrue(ft.missDecompositions.allSatisfy { $0.sentence.contains("published make band") })
    }

    func testNoReleaseDistanceMeansNoJacobianAndAStatedReason() throws {
        let rows = Self.records(Self.freeThrowSpec, sessionID: "s", date: Self.night, firstID: 1, seed: 7)
            .map { r -> ShotRecord in var x = r; x.releaseDistance = nil; return x }
        let ft = try XCTUnwrap(ShotDoctor.diagnose(records: rows).spot(.freeThrow))
        XCTAssertNil(ft.operatingPoint)
        XCTAssertTrue(try XCTUnwrap(ft.operatingPointUnavailableReason).contains("release distance"))
        XCTAssertNil(ft.attribution)
        XCTAssertNotNil(ft.attributionUnavailableReason)
        XCTAssertNil(ft.dominantCause)
        // Misses are still classified — depth does not need a Jacobian — but nothing is invented.
        XCTAssertEqual(ft.missDecompositions.count, 25)
        XCTAssertTrue(ft.missDecompositions.allSatisfy { $0.contributions.isEmpty && $0.unexplainedCm == nil })
    }

    func testBelowTheAttributionFloorNothingIsQuoted() throws {
        var spec = Self.freeThrowSpec
        spec.n = 12
        spec.makes = 3
        spec.unknown = 0
        let rows = Self.records(spec, sessionID: "s", date: Self.night, firstID: 1, seed: 7)
        let ft = try XCTUnwrap(ShotDoctor.diagnose(records: rows).spot(.freeThrow))
        XCTAssertNil(ft.attribution)
        XCTAssertTrue(try XCTUnwrap(ft.attributionUnavailableReason).contains("\(ShotDoctor.attributionFloor) shots"))
    }

    func testOneSpotCannotSpeakAboutVersatility() throws {
        let rows = Self.records(Self.freeThrowSpec, sessionID: "s", date: Self.night, firstID: 1, seed: 7)
        let d = ShotDoctor.diagnose(records: rows)
        XCTAssertEqual(d.distance.versatility.verdict, .undecided)
        XCTAssertNotNil(d.distance.unavailableReason)
        XCTAssertTrue(d.distance.statements.isEmpty)

        let a = SymptomEngine.answer(symptom: .noPowerFromDistance, diagnosis: d, records: rows)
        let range = try XCTUnwrap(a.ranked.first { $0.hypothesis.id == .rangeStrengthLimit })
        XCTAssertEqual(range.verdict, .belowFloor)
        XCTAssertTrue(range.evidenceLine.contains("Cannot compare distances") || range.evidenceLine.contains("two different spots"))
    }

    func testSpinAndLateralHypothesesAskForTheBehindClipRatherThanGuessing() throws {
        let records = Self.tonight
        let d = ShotDoctor.diagnose(records: records)
        let a = SymptomEngine.answer(symptom: .rotationDiagonal, diagnosis: d, records: records)
        let byID = Dictionary(uniqueKeysWithValues: a.ranked.map { ($0.hypothesis.id, $0) })
        for id in [HypothesisID.spinAxisTilt, .forearmFlare, .lateralVariability, .shoulderSquareness] {
            let e = try XCTUnwrap(byID[id], "\(id) missing")
            XCTAssertEqual(e.verdict, .needsAnotherClip, "\(id): \(e.evidenceLine)")
            XCTAssertNotNil(e.filmThis)
        }
        XCTAssertTrue(try XCTUnwrap(byID[.spinAxisTilt]).evidenceLine.contains("tape"))
        XCTAssertNil(a.plan, "no supported hypothesis means no plan is handed over")
        XCTAssertTrue(a.honesty.first?.contains("Nothing in your data backs") ?? false)
    }

    // MARK: 6 — a clean shooter: nothing fires

    func testCleanShooterProducesNoFindingAndAStableSpread() throws {
        var ftSpec = Self.freeThrowSpec
        ftSpec.n = 40; ftSpec.makes = 26; ftSpec.unknown = 0
        ftSpec.speed = (7.17, 0.09); ftSpec.angleDeg = (49.9, 1.2); ftSpec.height = (2.13, 0.03)
        ftSpec.entryDeg = (45.0, 1.5); ftSpec.depth = (0.265, 0.08); ftSpec.dip = (0.76, 0.05)
        var threeSpec = Self.threeSpec
        threeSpec.n = 40; threeSpec.makes = 26; threeSpec.unknown = 0
        threeSpec.speed = (8.09, 0.09); threeSpec.angleDeg = (48.3, 1.3); threeSpec.height = (2.34, 0.03)
        threeSpec.entryDeg = (44.0, 1.6); threeSpec.depth = (0.265, 0.09); threeSpec.dip = (0.75, 0.06)

        let rows = Self.records(ftSpec, sessionID: "clean-ft", date: Self.night, firstID: 1, seed: 3)
            + Self.records(threeSpec, sessionID: "clean-three", date: Self.night, firstID: 200, seed: 5)
        let d = ShotDoctor.diagnose(records: rows)

        XCTAssertEqual(d.distance.versatility.verdict, .spreadStable)
        XCTAssertTrue(d.distance.versatility.sentence.contains("holds up with distance"))

        let a = SymptomEngine.answer(complaint: "when i get further out i cant get enough power",
                                     diagnosis: d, records: rows)
        XCTAssertEqual(a.symptom?.id, .noPowerFromDistance)
        XCTAssertFalse(a.ranked.contains { $0.verdict == .supported }, a.ranked.map(\.evidenceLine).joined(separator: "\n"))
        XCTAssertNil(a.plan)

        let short = SymptomEngine.answer(symptom: .shootingShort, diagnosis: d, records: rows, spot: .freeThrow)
        let byID = Dictionary(uniqueKeysWithValues: short.ranked.map { ($0.hypothesis.id, $0) })
        XCTAssertEqual(byID[.depthBiasShort]?.verdict, .notSupported)
        XCTAssertNil(short.plan)
    }

    // MARK: 7 — pass check and retention

    func testPassCheckAndRetentionScoreTheNextTwoSessions() throws {
        let baseline = ShotDoctor.diagnose(records: Self.tonight)
        let plan = FixLibrary.package(for: .rangeStrengthLimit)

        func session(threeSpeedSD: Double, id: String, day: Double) -> [ShotRecord] {
            var ft = Self.freeThrowSpec; ft.n = 30; ft.makes = 9; ft.unknown = 0
            var th = Self.threeSpec; th.n = 30; th.makes = 10; th.unknown = 0
            th.speed = (8.09, threeSpeedSD)
            let date = Self.night.addingTimeInterval(day * 86_400)
            return Self.records(ft, sessionID: id, date: date, firstID: 1000, seed: 41)
                 + Self.records(th, sessionID: id, date: date, firstID: 2000, seed: 43)
        }

        let improved = ShotDoctor.diagnose(records: session(threeSpeedSD: 0.30, id: "s2", day: 3))
        let r = FixLibrary.check(plan.passCheck, baseline: baseline, followUp: improved, spot: .three)
        XCTAssertEqual(r.passed, true, r.sentence)
        XCTAssertEqual(try XCTUnwrap(r.baselineValue), 0.63, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(r.followUpValue), 0.30, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(r.target), 0.63 / exp(1.96 / 29.0.squareRoot()), accuracy: 1e-9)

        let unchanged = ShotDoctor.diagnose(records: session(threeSpeedSD: 0.62, id: "s3", day: 6))
        XCTAssertEqual(FixLibrary.check(plan.passCheck, baseline: baseline, followUp: unchanged, spot: .three).passed, false)

        // Practised but not learned: passed straight after the drill, gone the session after.
        let lapsed = FixLibrary.retention(plan.passCheck, baseline: baseline, followUp: improved,
                                          retention: unchanged, spot: .three)
        XCTAssertEqual(lapsed.held, false)
        XCTAssertTrue(lapsed.sentence.contains("Practised, not learned"))

        let held = FixLibrary.retention(plan.passCheck, baseline: baseline, followUp: improved,
                                        retention: ShotDoctor.diagnose(records: session(threeSpeedSD: 0.28, id: "s4", day: 9)),
                                        spot: .three)
        XCTAssertEqual(held.held, true)

        // Too few shots is never a fail.
        var thin = Self.threeSpec; thin.n = 8; thin.makes = 3; thin.unknown = 0
        let thinSession = ShotDoctor.diagnose(records: Self.records(thin, sessionID: "s5", date: Self.night, firstID: 3000, seed: 47))
        let thinResult = FixLibrary.check(plan.passCheck, baseline: baseline, followUp: thinSession, spot: .three)
        XCTAssertNil(thinResult.passed)
        XCTAssertTrue(thinResult.sentence.contains("Not a fail"))
    }
}
