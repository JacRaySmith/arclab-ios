import XCTest
@testable import ShotGeometry

/// Practice against games (`GameTransfer`).
///
/// The whole point of this type is to refuse to draw a conclusion, so most of these tests assert a
/// refusal: below the floor there is no comparison, a gap smaller than the counts can resolve is
/// reported as exactly that, and a perfect run is never treated as certainty.
final class GameTransferTests: XCTestCase {

    private func tally(_ zone: GameShotZone, _ kind: GameShotKind, contested: Bool = false,
                       _ makes: Int, of attempts: Int, lateGame: Bool = false) -> GameShotTally {
        GameShotTally(zone: zone, kind: kind, contested: contested, attempts: attempts,
                      makes: makes, quarter: nil, lateGame: lateGame)
    }

    // MARK: The floor

    func testTheFloorIsTheAppsOwnFloorAndNotANewNumber() {
        XCTAssertEqual(GameTransfer.floor, ShotDoctor.attributionFloor)
        XCTAssertEqual(GameTransfer.floor, 20)
    }

    func testBelowTheFloorThereIsNoComparisonAndTheSentenceSaysHowManyMore() {
        let c = MakeRateComparison(label: "Three",
                                   practice: MakeCount(makes: 30, misses: 30),
                                   game: MakeCount(makes: 3, misses: 9))
        XCTAssertFalse(c.isAboveFloor)
        XCTAssertNil(c.gapIsBiggerThanLuck, "below the floor the answer is 'cannot tell', never a verdict")
        XCTAssertTrue(c.sentence.contains("Not enough game shots to tell"), c.sentence)
        XCTAssertTrue(c.sentence.contains("n = 12"), c.sentence)
        XCTAssertTrue(c.sentence.contains("needs 20"), c.sentence)
    }

    func testTooFewPracticeShotsIsAlsoARefusalAndSaysWhichSideIsShort() {
        let c = MakeRateComparison(label: "Everything",
                                   practice: MakeCount(makes: 4, misses: 4),
                                   game: MakeCount(makes: 20, misses: 20))
        XCTAssertTrue(c.sentence.contains("Not enough practice shots"), c.sentence)
        XCTAssertTrue(c.sentence.contains("n = 8"), c.sentence)
    }

    // MARK: The arithmetic

    /// The smallest tellable gap is the 95 % Wald interval on a difference of proportions. At 20 a
    /// side and rates near half that is about 31 points — which is the number the research note
    /// quotes, so if the formula moves the document is wrong too.
    func testTheSmallestTellableGapIsTheStatedArithmetic() {
        let half = MakeCount(makes: 10, misses: 10)
        guard let d = GameTransfer.detectableMakeRateDifference(practice: half, game: half) else {
            return XCTFail("no difference at n = 20 a side")
        }
        XCTAssertEqual(d, 1.96 * (0.25 / 20 + 0.25 / 20).squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(Int((d * 100).rounded()), 31)

        let fifty = MakeCount(makes: 25, misses: 25)
        XCTAssertEqual(Int((GameTransfer.detectableMakeRateDifference(practice: fifty, game: fifty)! * 100).rounded()), 20)
        let hundred = MakeCount(makes: 50, misses: 50)
        XCTAssertEqual(Int((GameTransfer.detectableMakeRateDifference(practice: hundred, game: hundred)! * 100).rounded()), 14)
    }

    /// A perfect run is not certainty. Wald's standard error collapses to zero at p = 1, which would
    /// have the app claim it could resolve a gap of nothing at all.
    func testAPerfectRunIsNeverTreatedAsCertainty() {
        let perfect = MakeCount(makes: 25, misses: 0)
        let half = MakeCount(makes: 12, misses: 13)
        guard let d = GameTransfer.detectableMakeRateDifference(practice: perfect, game: half) else {
            return XCTFail("no difference")
        }
        XCTAssertGreaterThan(d, 0.2, "a 25-from-25 side must still carry the widest case, not zero spread")
        let none = MakeCount(makes: 0, misses: 25)
        guard let zero = GameTransfer.detectableMakeRateDifference(practice: none, game: half) else {
            return XCTFail("no difference for a 0-from-25 side")
        }
        XCTAssertEqual(zero, d, accuracy: 1e-12, "0 % gets the same treatment as 100 %")
    }

    func testNoCountsMeansNoNumber() {
        XCTAssertNil(MakeCount.none.rate)
        XCTAssertNil(GameTransfer.detectableMakeRateDifference(practice: .none, game: MakeCount(makes: 5, misses: 5)))
        let c = MakeRateComparison(label: "Elbow", practice: .none, game: .none)
        XCTAssertNil(c.gap)
        XCTAssertNil(c.smallestTellableGap)
    }

    func testUnknownOutcomesAreCarriedAndNeverCountedAsEither() {
        let c = MakeCount(makes: 10, misses: 10, unknown: 7)
        XCTAssertEqual(c.n, 20, "a shot the app did not see resolve is not half a make")
        XCTAssertEqual(c.rate, 0.5)
        XCTAssertEqual((c + MakeCount(makes: 1, misses: 1, unknown: 1)).unknown, 8)
    }

    // MARK: The verdict

    func testAGapInsideTheNoiseIsReportedAsInsideTheNoise() {
        let c = MakeRateComparison(label: "Three",
                                   practice: MakeCount(makes: 11, misses: 9),   // 55 %
                                   game: MakeCount(makes: 9, misses: 11))       // 45 %
        XCTAssertTrue(c.isAboveFloor)
        XCTAssertEqual(c.gapIsBiggerThanLuck, false)
        XCTAssertTrue(c.sentence.contains("not yet more than luck"), c.sentence)
        XCTAssertTrue(c.sentence.contains("55 %") && c.sentence.contains("45 %"), c.sentence)
        XCTAssertTrue(c.sentence.contains("n = 20"), c.sentence)
    }

    func testAGapBiggerThanTheNoiseIsSaidPlainlyAndNamesTheDirection() {
        let c = MakeRateComparison(label: "Three",
                                   practice: MakeCount(makes: 45, misses: 15),  // 75 %
                                   game: MakeCount(makes: 8, misses: 22))       // 27 %
        XCTAssertEqual(c.gapIsBiggerThanLuck, true)
        XCTAssertTrue(c.sentence.contains("bigger than luck explains"), c.sentence)
        XCTAssertTrue(c.sentence.contains("in practice's favour"), c.sentence)
    }

    func testTheSentenceAlwaysCarriesBothCountsSoNeitherRateStandsAlone() {
        let c = MakeRateComparison(label: "Everything",
                                   practice: MakeCount(makes: 40, misses: 20),
                                   game: MakeCount(makes: 10, misses: 15))
        XCTAssertTrue(c.sentence.contains("n = 60"), c.sentence)
        XCTAssertTrue(c.sentence.contains("n = 25"), c.sentence)
    }

    // MARK: Zones

    func testAZoneWithNoPracticeBehindItIsNeverCompared() {
        XCTAssertNil(GameShotZone.atTheRim.practiceSpot)
        XCTAssertNotNil(GameShotZone.atTheRim.noPracticeReason)
        for zone in GameShotZone.allCases where zone != .atTheRim {
            XCTAssertNotNil(zone.practiceSpot, "\(zone.rawValue) has no practice spot to compare against")
            XCTAssertNil(zone.noPracticeReason)
            XCTAssertFalse(zone.name.isEmpty)
        }
        let byZone = GameTransfer.byZone(practiceBySpot: [:], game: [tally(.atTheRim, .offTheDribble, 6, of: 8)])
        XCTAssertTrue(byZone.isEmpty, "shots at the rim must not appear as a comparison at all")
    }

    func testZonesComeBackNearToFarAndOnlyWhereThereIsSomethingToShow() {
        let practice: [DoctorSpot: MakeCount] = [
            .three: MakeCount(makes: 20, misses: 20),
            .freeThrow: MakeCount(makes: 30, misses: 10),
        ]
        let game = [tally(.three, .catchAndShoot, 4, of: 12), tally(.freeThrow, .freeThrow, 6, of: 8)]
        let rows = GameTransfer.byZone(practiceBySpot: practice, game: game)
        XCTAssertEqual(rows.map(\.label), ["Free throws", "Three"])
        XCTAssertEqual(rows[1].game.n, 12)
        XCTAssertEqual(rows[1].practice.n, 40)
        // A zone with nothing on either side is left out rather than shown as an empty row.
        XCTAssertFalse(rows.contains { $0.label == "Elbow" })
    }

    func testTheOverallComparisonPoolsOnlyTheGameSide() {
        let game = [tally(.three, .catchAndShoot, 3, of: 10), tally(.midRange, .offTheDribble, 5, of: 10)]
        let c = GameTransfer.overall(practice: MakeCount(makes: 30, misses: 30), game: game)
        XCTAssertEqual(c.label, "Everything")
        XCTAssertEqual(c.game.n, 20)
        XCTAssertEqual(c.game.makes, 8)
    }

    // MARK: Game-only splits

    func testTheShotTypeSplitIsGameAgainstGameBecausePracticeCarriesNoSuchLabel() {
        let game = [tally(.three, .catchAndShoot, 12, of: 30),
                    tally(.midRange, .offTheDribble, 4, of: 25),
                    tally(.freeThrow, .freeThrow, 8, of: 10)]
        let splits = GameTransfer.gameSplits(game)
        XCTAssertEqual(splits.map(\.label), ["How the shot came about", "Open or contested"])
        let byKind = splits[0]
        XCTAssertEqual(byKind.left.count.n, 30)
        XCTAssertEqual(byKind.right.count.n, 25)
        XCTAssertTrue(byKind.isAboveFloor)
        XCTAssertTrue(byKind.sentence.contains("Catch and shoot"), byKind.sentence)
        // Free throws sit in neither column of the open/contested split.
        XCTAssertEqual(splits[1].left.count.n + splits[1].right.count.n, 55)
    }

    func testAGameSplitUnderTheFloorSaysSoRatherThanComparing() {
        let game = [tally(.three, .catchAndShoot, 2, of: 5), tally(.three, .offTheDribble, contested: true, 1, of: 4)]
        let splits = GameTransfer.gameSplits(game)
        XCTAssertFalse(splits.isEmpty)
        for s in splits {
            XCTAssertFalse(s.isAboveFloor)
            XCTAssertTrue(s.sentence.contains("Not enough game shots to tell"), s.sentence)
        }
    }

    func testAnEmptyLogProducesNoSplitsAtAll() {
        XCTAssertTrue(GameTransfer.gameSplits([]).isEmpty)
        XCTAssertEqual(GameTransfer.total([]), .none)
    }

    // MARK: The tally itself

    func testATallyCannotRecordMoreMakesThanAttempts() {
        let t = GameShotTally(zone: .three, kind: .catchAndShoot, contested: false, attempts: 3, makes: 9)
        XCTAssertEqual(t.makes, 3)
        XCTAssertEqual(GameShotTally(zone: .three, kind: .catchAndShoot, contested: false,
                                     attempts: -4, makes: -2).attempts, 0)
    }

    // MARK: What the shooter is told

    func testTheHonestyRulesSayTheTwoCountsAreDifferentMeasurementsAndRefuseStreaks() {
        XCTAssertGreaterThanOrEqual(GameTransfer.honestyRules.count, 4)
        let all = GameTransfer.honestyRules.joined(separator: " ")
        XCTAssertTrue(all.contains("never added together"), all)
        XCTAssertTrue(all.contains("streaks"), all)
        XCTAssertTrue(all.contains("\(GameTransfer.floor)"), all)
        for r in GameTransfer.honestyRules { XCTAssertFalse(r.isEmpty) }
    }

    func testPercentAndPointsReadTheWayAPersonSaysThem() {
        XCTAssertEqual(GameTransfer.percent(0.425), "43 %")
        XCTAssertEqual(GameTransfer.points(0.14), "14 points")
        XCTAssertEqual(GameTransfer.points(0.01), "1 point")
    }
}
