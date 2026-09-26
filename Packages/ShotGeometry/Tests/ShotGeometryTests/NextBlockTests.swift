import XCTest
@testable import ShotGeometry

/// The next-block decision table (`NextBlock.decide`).
///
/// One test per row: inputs → the block that comes next → the reason key it was proposed under.
/// The sentences themselves are checked only where they carry a number the shooter is being asked to
/// trust (the shot count a repeat block buys, the detectable ratio at that count, the cap's own
/// admission that it is a convention).
final class NextBlockTests: XCTestCase {

    /// The user's real plan on 2026-09-19: speed variability at free throws, release-speed SD,
    /// minimum n 25, drill "One-spot depth band" (10 reps, no ladder).
    private func state(last: NextBlock.LastBlock?,
                       hasPlan: Bool = true,
                       hasBaseline: Bool = true,
                       ladder: [DoctorSpot] = [],
                       spotsDoneToday: [DoctorSpot] = [.freeThrow],
                       blocksDoneToday: Int = 1,
                       shotsToday: Int = 10,
                       spreadWidens: Bool? = nil,
                       proposalsToday: [NextBlock.ReasonKey] = [],
                       cap: NextBlock.Cap = .default) -> NextBlock.State {
        NextBlock.State(last: last, hasPlan: hasPlan, hasBaseline: hasBaseline, planSpot: .freeThrow,
                        measureName: "release-speed spread (SD)", measureUnit: "m/s", measureDecimals: 3,
                        grade: .a, minimumN: 25, targetNarrowsSpread: true,
                        drillName: "One-spot depth band", drillReps: 10, drillLadder: ladder,
                        spotsDoneToday: spotsDoneToday, blocksDoneToday: blocksDoneToday,
                        shotsToday: shotsToday, spreadWidensWithDistance: spreadWidens,
                        proposalsToday: proposalsToday, cap: cap)
    }

    // MARK: Nothing done yet

    func testNoPlanAndNoBlocksProposesABaseline() {
        let d = NextBlock.decide(state(last: nil, hasPlan: false, hasBaseline: false,
                                       spotsDoneToday: [], blocksDoneToday: 0, shotsToday: 0))
        XCTAssertEqual(d.plan.reasonKey, .firstBlock)
        XCTAssertEqual(d.plan.role, .baseline)
        XCTAssertFalse(d.plan.cued)
        XCTAssertEqual(d.plan.shots, 10)
        XCTAssertTrue(d.isToday)
    }

    func testPlanWithNoBlocksYetOpensOnTheDrill() {
        let d = NextBlock.decide(state(last: nil, spotsDoneToday: [], blocksDoneToday: 0, shotsToday: 0))
        XCTAssertEqual(d.plan.reasonKey, .startOfDay)
        XCTAssertEqual(d.plan.role, .drill)
        XCTAssertTrue(d.plan.cued)
    }

    // MARK: Baseline → drill

    func testScoredBaselineProposesTheDrillAndQuotesTheNumberWithItsN() {
        let last = NextBlock.LastBlock(role: .baseline, spot: .freeThrow, countedShots: 9,
                                       measureValue: 0.186, measureN: 9)
        let d = NextBlock.decide(state(last: last))
        XCTAssertEqual(d.plan.reasonKey, .baselineToDrill)
        XCTAssertEqual(d.plan.role, .drill)
        XCTAssertEqual(d.plan.spot, .freeThrow)
        XCTAssertEqual(d.plan.shots, 10)
        XCTAssertTrue(d.plan.cued)
        XCTAssertTrue(d.plan.reason.contains("0.186 m/s"), d.plan.reason)
        XCTAssertTrue(d.plan.reason.contains("n = 9"), d.plan.reason)
        XCTAssertTrue(d.plan.reason.contains("grade A"), d.plan.reason)
    }

    func testBaselineWithNoNumberAsksForTheSameBlockAgainAndKeepsTheScorersReason() {
        let why = "This block carries no release-speed spread (SD): the follow-up session has 3 shots."
        let last = NextBlock.LastBlock(role: .baseline, spot: .freeThrow, countedShots: 3,
                                       measureUnavailableReason: why)
        let d = NextBlock.decide(state(last: last))
        XCTAssertEqual(d.plan.reasonKey, .baselineNeedsShots)
        XCTAssertEqual(d.plan.role, .baseline)
        XCTAssertFalse(d.plan.cued)
        XCTAssertEqual(d.plan.reason, why)
    }

    func testBaselineWithNoPlanCountsTowardsTheAttributionFloor() {
        let last = NextBlock.LastBlock(role: .baseline, spot: .three, countedShots: 8, measureN: 8)
        let d = NextBlock.decide(state(last: last, hasPlan: false, hasBaseline: false, spotsDoneToday: [.three]))
        XCTAssertEqual(d.plan.reasonKey, .noPlanMoreShots)
        XCTAssertEqual(d.plan.role, .baseline)
        XCTAssertEqual(d.plan.spot, .three)
        // 20 − 8 = 12, rounded up to a block of 15.
        XCTAssertEqual(d.plan.shots, 15)
        XCTAssertTrue(d.plan.whatItBuys.contains("\(ShotDoctor.attributionFloor) counted shots"), d.plan.whatItBuys)
    }

    /// The real day logged on 2026-09-19: a speed-variability plan whose baseline session had been
    /// deleted, so the session was built as one un-cued block and the app then had nothing to say.
    func testAPlanWhoseBaselineIsGoneStillProposesTheDrillAndSaysWhyNothingCanBeScored() {
        let why = "No active plan with a baseline session, so there is no pass measure to score this block on."
        let last = NextBlock.LastBlock(role: .baseline, spot: .freeThrow, countedShots: 9,
                                       measureUnavailableReason: why)
        let d = NextBlock.decide(state(last: last, hasBaseline: false))
        XCTAssertEqual(d.plan.reasonKey, .planNeedsNewBaseline)
        XCTAssertEqual(d.plan.role, .drill)
        XCTAssertEqual(d.plan.spot, .freeThrow)
        XCTAssertTrue(d.plan.cued)
        XCTAssertTrue(d.plan.reason.contains("is gone"), d.plan.reason)
        XCTAssertTrue(d.isToday)
    }

    func testAPlanWhoseBaselineIsGoneOpensTheDayOnAnUncuedBlock() {
        let d = NextBlock.decide(state(last: nil, hasBaseline: false, spotsDoneToday: [],
                                       blocksDoneToday: 0, shotsToday: 0))
        XCTAssertEqual(d.plan.reasonKey, .planNeedsNewBaseline)
        XCTAssertEqual(d.plan.role, .baseline)
        XCTAssertFalse(d.plan.cued)
    }

    // MARK: Under the floor

    func testDrillUnderTheShotFloorAsksForTheShotsItNeedsAndSaysWhatTheyBuy() {
        let last = NextBlock.LastBlock(role: .drill, spot: .freeThrow, countedShots: 10,
                                       measureValue: 0.171, measureN: 10, hasCheck: true, checkPassed: nil)
        let d = NextBlock.decide(state(last: last, blocksDoneToday: 2, shotsToday: 20))
        XCTAssertEqual(d.plan.reasonKey, .notEnoughShots)
        XCTAssertEqual(d.plan.role, .drill)
        XCTAssertEqual(d.plan.spot, .freeThrow)
        // 25 − 10 = 15 more shots, which lands on n = 25.
        XCTAssertEqual(d.plan.shots, 15)
        XCTAssertTrue(d.plan.reason.contains("not enough shots to tell"), d.plan.reason)
        XCTAssertTrue(d.plan.reason.contains("needs 25"), d.plan.reason)
        XCTAssertTrue(d.plan.whatItBuys.contains("n = 25"), d.plan.whatItBuys)
        // exp(1.96/√25) = 1.48× — quoted, not invented.
        XCTAssertTrue(d.plan.whatItBuys.contains("1.48×"), d.plan.whatItBuys)
    }

    func testARepeatIsNeverSmallerThanFiveShots() {
        let last = NextBlock.LastBlock(role: .drill, spot: .freeThrow, countedShots: 24,
                                       measureValue: 0.17, measureN: 24, hasCheck: true, checkPassed: nil)
        let d = NextBlock.decide(state(last: last, blocksDoneToday: 2, shotsToday: 24))
        XCTAssertEqual(d.plan.shots, 5)
    }

    func testDrillWithNoMeasureAtAllRepeatsTheBlockWithTheScorersReason() {
        let why = "This block carries no release-speed spread (SD): every window was refused by the shot gate."
        let last = NextBlock.LastBlock(role: .drill, spot: .elbow, countedShots: 0,
                                       measureUnavailableReason: why, hasCheck: false)
        let d = NextBlock.decide(state(last: last, spotsDoneToday: [.elbow]))
        XCTAssertEqual(d.plan.reasonKey, .measureUnavailable)
        XCTAssertEqual(d.plan.spot, .elbow)
        XCTAssertEqual(d.plan.reason, why)
    }

    // MARK: The number did not move

    func testFlatMeasureRepeatsTheSetAndSaysOneSetIsNotAVerdict() {
        let last = NextBlock.LastBlock(role: .drill, spot: .freeThrow, countedShots: 26,
                                       measureValue: 0.182, measureN: 26, hasCheck: true,
                                       checkPassed: false, checkBaselineValue: 0.186, checkTarget: 0.126)
        let d = NextBlock.decide(state(last: last, blocksDoneToday: 2, shotsToday: 30))
        XCTAssertEqual(d.plan.reasonKey, .measureFlat)
        XCTAssertEqual(d.plan.role, .drill)
        XCTAssertEqual(d.plan.spot, .freeThrow)
        XCTAssertTrue(d.plan.reason.contains("0.186 m/s → 0.182 m/s"), d.plan.reason)
        XCTAssertTrue(d.plan.reason.contains("target of 0.126 m/s"), d.plan.reason)
    }

    func testFlatMeasureWithSpreadWideningStepsOutIntoARangeBlock() {
        let last = NextBlock.LastBlock(role: .drill, spot: .freeThrow, countedShots: 26,
                                       measureValue: 0.182, measureN: 26, hasCheck: true,
                                       checkPassed: false, checkBaselineValue: 0.186, checkTarget: 0.126)
        let d = NextBlock.decide(state(last: last, blocksDoneToday: 2, shotsToday: 30, spreadWidens: true))
        XCTAssertEqual(d.plan.reasonKey, .rangeExtension)
        XCTAssertEqual(d.plan.spot, .elbow)   // one step out from free throws
        XCTAssertTrue(d.plan.reason.contains("grade A"), d.plan.reason)
        XCTAssertTrue(d.plan.instruction.contains("Step-in"), d.plan.instruction)
    }

    func testSpreadWideningIsNeverAssumedWhenItWasNotMeasured() {
        let last = NextBlock.LastBlock(role: .drill, spot: .freeThrow, countedShots: 26,
                                       measureValue: 0.182, measureN: 26, hasCheck: true,
                                       checkPassed: false, checkBaselineValue: 0.186, checkTarget: 0.126)
        let d = NextBlock.decide(state(last: last, blocksDoneToday: 2, shotsToday: 30, spreadWidens: nil))
        XCTAssertEqual(d.plan.reasonKey, .measureFlat)
    }

    // MARK: The number moved

    func testPassedDrillWithALadderGoesToTheNextSpotNotYetShotToday() {
        let last = NextBlock.LastBlock(role: .drill, spot: .freeThrow, countedShots: 26,
                                       measureValue: 0.121, measureN: 26, hasCheck: true,
                                       checkPassed: true, checkBaselineValue: 0.186, checkTarget: 0.126)
        let d = NextBlock.decide(state(last: last, ladder: [.freeThrow, .elbow, .midRange, .three],
                                       spotsDoneToday: [.freeThrow], blocksDoneToday: 2, shotsToday: 30))
        XCTAssertEqual(d.plan.reasonKey, .ladderNextSpot)
        XCTAssertEqual(d.plan.spot, .elbow)
        XCTAssertTrue(d.plan.cued)
    }

    func testPassedDrillWithTheLadderDoneTakesTheCueAway() {
        let last = NextBlock.LastBlock(role: .drill, spot: .three, countedShots: 26,
                                       measureValue: 0.121, measureN: 26, hasCheck: true,
                                       checkPassed: true, checkBaselineValue: 0.186, checkTarget: 0.126)
        let d = NextBlock.decide(state(last: last, ladder: [.freeThrow, .three],
                                       spotsDoneToday: [.freeThrow, .three], blocksDoneToday: 3, shotsToday: 40))
        XCTAssertEqual(d.plan.reasonKey, .drillMovedToRetention)
        XCTAssertEqual(d.plan.role, .retention)
        XCTAssertFalse(d.plan.cued)
        XCTAssertEqual(d.plan.spot, .freeThrow)   // the plan's spot, not the last block's
    }

    // MARK: Retention

    func testRetentionThatHeldStepsOneSpotFartherOut() {
        let last = NextBlock.LastBlock(role: .retention, spot: .freeThrow, countedShots: 10,
                                       measureValue: 0.119, measureN: 10, hasCheck: true, checkPassed: true)
        let d = NextBlock.decide(state(last: last, blocksDoneToday: 3, shotsToday: 40))
        XCTAssertEqual(d.plan.reasonKey, .retentionHeld)
        XCTAssertEqual(d.plan.spot, .elbow)
        XCTAssertTrue(d.isToday)
    }

    func testRetentionThatHeldWithNowhereToStepEndsTheDayAndGivesTomorrowsBlock() {
        let last = NextBlock.LastBlock(role: .retention, spot: .three, countedShots: 10,
                                       measureValue: 0.119, measureN: 10, hasCheck: true, checkPassed: true)
        var s = state(last: last, spotsDoneToday: [.three], blocksDoneToday: 3, shotsToday: 40)
        s.planSpot = .three
        let d = NextBlock.decide(s)
        XCTAssertFalse(d.isToday)
        XCTAssertNotNil(d.dayDoneReason)
        XCTAssertEqual(d.plan.role, .retention)
        XCTAssertFalse(d.plan.cued)
        XCTAssertTrue(d.plan.instruction.contains("Tomorrow"), d.plan.instruction)
    }

    func testRetentionThatDidNotHoldGoesBackToCuedReps() {
        let last = NextBlock.LastBlock(role: .retention, spot: .freeThrow, countedShots: 10,
                                       measureValue: 0.184, measureN: 10, hasCheck: true,
                                       checkPassed: false, checkBaselineValue: 0.121)
        let d = NextBlock.decide(state(last: last, blocksDoneToday: 3, shotsToday: 40))
        XCTAssertEqual(d.plan.reasonKey, .retentionNotHeld)
        XCTAssertEqual(d.plan.role, .drill)
        XCTAssertTrue(d.plan.cued)
        XCTAssertTrue(d.plan.reason.contains("practised, not learned"), d.plan.reason)
    }

    func testRetentionThatCannotBeJudgedAsksForMoreShotsNotAFail() {
        let last = NextBlock.LastBlock(role: .retention, spot: .freeThrow, countedShots: 8,
                                       measureValue: 0.13, measureN: 8, hasCheck: true, checkPassed: nil)
        let d = NextBlock.decide(state(last: last, blocksDoneToday: 3, shotsToday: 40))
        XCTAssertEqual(d.plan.reasonKey, .notEnoughShots)
        XCTAssertEqual(d.plan.role, .retention)
        XCTAssertFalse(d.plan.cued)
        XCTAssertTrue(d.plan.reason.contains("not enough shots to tell"), d.plan.reason)
    }

    // MARK: Learn blocks

    func testALearnBlockSendsYouBackToThePlansOwnMeasure() {
        let last = NextBlock.LastBlock(role: .drill, spot: .elbow, countedShots: 12,
                                       measureValue: 44.2, measureN: 12, hasCheck: true,
                                       checkPassed: nil, fromLearnModule: true)
        let d = NextBlock.decide(state(last: last, spotsDoneToday: [.elbow], blocksDoneToday: 2, shotsToday: 22))
        XCTAssertEqual(d.plan.reasonKey, .afterLearnBlock)
        XCTAssertEqual(d.plan.role, .drill)
        XCTAssertEqual(d.plan.spot, .freeThrow)
    }

    // MARK: The cap

    func testTheCapEndsTheDayAndStillNamesTomorrowsBlock() {
        let last = NextBlock.LastBlock(role: .drill, spot: .freeThrow, countedShots: 26,
                                       measureValue: 0.182, measureN: 26, hasCheck: true,
                                       checkPassed: false, checkBaselineValue: 0.186, checkTarget: 0.126)
        let d = NextBlock.decide(state(last: last, blocksDoneToday: 8, shotsToday: 90))
        XCTAssertFalse(d.isToday)
        XCTAssertEqual(d.plan.reasonKey, .measureFlat)      // the same block, just tomorrow
        XCTAssertTrue(d.dayDoneReason?.contains("convention") == true, d.dayDoneReason ?? "")
        XCTAssertTrue(d.dayDoneReason?.contains("grade A") == true, d.dayDoneReason ?? "")
    }

    func testTheShotCapAlsoEndsTheDay() {
        let last = NextBlock.LastBlock(role: .baseline, spot: .freeThrow, countedShots: 10,
                                       measureValue: 0.186, measureN: 10)
        let d = NextBlock.decide(state(last: last, blocksDoneToday: 4, shotsToday: 100))
        XCTAssertFalse(d.isToday)
        XCTAssertEqual(d.plan.reasonKey, .baselineToDrill)
    }

    func testTheDayIsNeverEmptyForAnyRowOfTheTable() {
        // Every combination of role × verdict × spread-widening still produces a block to shoot.
        for role in NextBlock.Role.allCases {
            for passed in [true, false, nil] as [Bool?] {
                for widens in [true, false, nil] as [Bool?] {
                    let last = NextBlock.LastBlock(role: role, spot: .freeThrow, countedShots: 26,
                                                   measureValue: 0.18, measureN: 26, hasCheck: true,
                                                   checkPassed: passed, checkBaselineValue: 0.186,
                                                   checkTarget: 0.126)
                    let d = NextBlock.decide(state(last: last, spreadWidens: widens))
                    XCTAssertGreaterThan(d.plan.shots, 0)
                    XCTAssertFalse(d.plan.instruction.isEmpty)
                    XCTAssertFalse(d.plan.reason.isEmpty)
                    XCTAssertFalse(d.plan.whatItBuys.isEmpty)
                }
            }
        }
    }

    // MARK: Game-like variants (added 2026-09-19)

    /// Nothing game-like is offered before anything has moved: a shooter with no measured change has
    /// nothing to carry into a harder condition.
    func testNoGameLikeBlocksBeforeAnythingHasMoved() {
        let flat = NextBlock.LastBlock(role: .drill, spot: .freeThrow, countedShots: 26,
                                       measureValue: 0.185, measureN: 26, hasCheck: true,
                                       checkPassed: false, checkBaselineValue: 0.186, checkTarget: 0.126)
        XCTAssertTrue(NextBlock.decide(state(last: flat)).alternatives.isEmpty)

        let cannotTell = NextBlock.LastBlock(role: .drill, spot: .freeThrow, countedShots: 8,
                                             measureValue: 0.13, measureN: 8, hasCheck: true, checkPassed: nil)
        XCTAssertTrue(NextBlock.decide(state(last: cannotTell)).alternatives.isEmpty)

        let noPlan = NextBlock.LastBlock(role: .baseline, spot: .freeThrow, countedShots: 10,
                                         measureValue: 0.186, measureN: 10)
        XCTAssertTrue(NextBlock.decide(state(last: noPlan, hasPlan: false, hasBaseline: false)).alternatives.isEmpty)
    }

    /// A drill block that passed gets the two practice-schedule variants and **not** tiredness: the
    /// change appeared today, so nothing is stacked on top of it on the same day.
    func testPassedDrillOffersShuffledSpotsAndACalledCatchButNotTiredness() {
        let last = NextBlock.LastBlock(role: .drill, spot: .freeThrow, countedShots: 26,
                                       measureValue: 0.118, measureN: 26, hasCheck: true,
                                       checkPassed: true, checkBaselineValue: 0.186, checkTarget: 0.126)
        let d = NextBlock.decide(state(last: last))
        XCTAssertEqual(d.alternatives.map(\.gameLike), [.randomSpot, .decisionCalled])
        for plan in d.alternatives {
            XCTAssertFalse(plan.cued, "a game-like block tests the change without the cue")
            XCTAssertGreaterThan(plan.shots, 0)
            XCTAssertFalse(plan.instruction.isEmpty)
            XCTAssertFalse(plan.whatItBuys.isEmpty)
            XCTAssertTrue(plan.whatItBuys.contains("app"), plan.whatItBuys)
        }
    }

    /// The main proposal is untouched by the alternatives — the table's existing rows still decide
    /// what comes next, and the game-like blocks sit beside it.
    func testGameLikeBlocksAreOfferedAlongsideTheLadderNotInsteadOfIt() {
        let last = NextBlock.LastBlock(role: .drill, spot: .freeThrow, countedShots: 26,
                                       measureValue: 0.118, measureN: 26, hasCheck: true,
                                       checkPassed: true, checkBaselineValue: 0.186, checkTarget: 0.126)
        let d = NextBlock.decide(state(last: last, ladder: [.freeThrow, .elbow], spotsDoneToday: [.freeThrow]))
        XCTAssertEqual(d.plan.reasonKey, .ladderNextSpot)
        XCTAssertEqual(d.plan.spot, .elbow)
        XCTAssertNil(d.plan.gameLike, "the day's own block is never a game-like one")
        XCTAssertFalse(d.alternatives.isEmpty)
    }

    /// Once an un-cued block has held, all four conditions are on offer.
    func testRetentionThatHeldOffersAllFourGameLikeConditions() {
        let last = NextBlock.LastBlock(role: .retention, spot: .freeThrow, countedShots: 10,
                                       measureValue: 0.119, measureN: 10, hasCheck: true, checkPassed: true)
        let d = NextBlock.decide(state(last: last, blocksDoneToday: 3, shotsToday: 40))
        XCTAssertEqual(d.plan.reasonKey, .retentionHeld)          // the existing row is unchanged
        XCTAssertEqual(d.alternatives.map(\.gameLike), [.randomSpot, .decisionCalled, .contested, .fatigued])
        XCTAssertEqual(Set(d.alternatives.map(\.reasonKey)),
                       [.gameLikeRandomSpot, .gameLikeDecisionCalled, .gameLikeContested, .gameLikeFatigued])
        for plan in d.alternatives {
            XCTAssertTrue(plan.reason.contains("cue taken away"), plan.reason)
        }
    }

    /// Every variant states what the app cannot see, in the block itself rather than in a footnote.
    func testEveryVariantSaysWhatTheAppCannotSee() {
        for v in NextBlock.GameLikeVariant.allCases {
            XCTAssertFalse(v.title.isEmpty)
            XCTAssertFalse(v.limit.isEmpty)
            XCTAssertFalse(v.source.isEmpty)
            XCTAssertTrue(v.limit.contains("app"), "\(v.rawValue): the limit must be about what the app does — \(v.limit)")
        }
        XCTAssertEqual(NextBlock.GameLikeVariant.fatigued.grade, .a)
        XCTAssertEqual(NextBlock.GameLikeVariant.randomSpot.grade, .b)
    }

    /// The day cap still governs: a capped day offers no extra blocks at all.
    func testTheCapSilencesTheGameLikeOffers() {
        let last = NextBlock.LastBlock(role: .retention, spot: .freeThrow, countedShots: 10,
                                       measureValue: 0.119, measureN: 10, hasCheck: true, checkPassed: true)
        let d = NextBlock.decide(state(last: last, blocksDoneToday: 8, shotsToday: 95))
        XCTAssertFalse(d.isToday)
        XCTAssertTrue(d.alternatives.isEmpty, "the day is over; nothing extra is offered on top of it")
    }

    /// A Learn block is scored on its module's gate, so it never earns a game-like offer from a plan.
    func testALearnBlockNeverEarnsAGameLikeOffer() {
        let last = NextBlock.LastBlock(role: .drill, spot: .elbow, countedShots: 12,
                                       measureValue: 44.2, measureN: 12, hasCheck: true,
                                       checkPassed: true, fromLearnModule: true)
        XCTAssertTrue(NextBlock.decide(state(last: last)).alternatives.isEmpty)
    }

    /// A block shot under a game-like condition is never scored against the plan's baseline — that
    /// baseline was not shot tired or contested, so the check would report the condition as a
    /// failure of the fix. What comes next is the ordinary version of the same block.
    func testAGameLikeBlockIsFollowedByItsOwnOrdinaryComparison() {
        for variant in NextBlock.GameLikeVariant.allCases {
            let last = NextBlock.LastBlock(role: .drill, spot: .three, countedShots: 10,
                                           measureValue: 0.204, measureN: 10, gameLike: variant)
            let d = NextBlock.decide(state(last: last, spotsDoneToday: [.three], blocksDoneToday: 3, shotsToday: 40))
            XCTAssertEqual(d.plan.reasonKey, .afterGameLikeBlock, variant.rawValue)
            XCTAssertEqual(d.plan.role, .baseline)
            XCTAssertEqual(d.plan.spot, .three, "the comparison has to be at the same spot")
            XCTAssertFalse(d.plan.cued)
            XCTAssertTrue(d.plan.reason.contains("not scored against the plan"), d.plan.reason)
            XCTAssertTrue(d.plan.reason.contains("0.204 m/s"), d.plan.reason)
            XCTAssertTrue(d.plan.reason.contains(variant.limit), d.plan.reason)
            XCTAssertTrue(d.plan.whatItBuys.contains("same day"), d.plan.whatItBuys)
            XCTAssertTrue(d.alternatives.isEmpty, "one game-like block does not earn another")
        }
    }

    /// The game-like row sits behind the Learn row and behind the missing-baseline row, both of
    /// which describe a state in which nothing can be scored at all.
    func testALearnBlockAndAMissingBaselineStillWinOverTheGameLikeRow() {
        let learn = NextBlock.LastBlock(role: .drill, spot: .elbow, countedShots: 10,
                                        measureValue: 0.2, measureN: 10,
                                        fromLearnModule: true, gameLike: .contested)
        XCTAssertEqual(NextBlock.decide(state(last: learn)).plan.reasonKey, .afterLearnBlock)

        let noBaseline = NextBlock.LastBlock(role: .drill, spot: .elbow, countedShots: 10,
                                             measureValue: 0.2, measureN: 10, gameLike: .fatigued)
        XCTAssertEqual(NextBlock.decide(state(last: noBaseline, hasBaseline: false)).plan.reasonKey,
                       .planNeedsNewBaseline)
    }

    // MARK: The shuffled order

    func testTheShuffledOrderIsTheRightLengthUsesEverySpotAndNeverRepeatsBackToBack() {
        let spots: [DoctorSpot] = [.freeThrow, .elbow, .midRange, .three]
        for seed in UInt64(0)..<40 {
            let order = NextBlock.randomSpotSequence(spots: spots, shots: 12, seed: seed)
            XCTAssertEqual(order.count, 12)
            XCTAssertEqual(Set(order), Set(spots), "seed \(seed) dropped a spot")
            for i in 1..<order.count {
                XCTAssertNotEqual(order[i], order[i - 1], "seed \(seed) put \(order[i].rawValue) twice in a row")
            }
        }
    }

    func testTheShuffledOrderIsTheSameEveryTimeForTheSameDay() {
        let spots: [DoctorSpot] = [.freeThrow, .elbow, .midRange]
        XCTAssertEqual(NextBlock.randomSpotSequence(spots: spots, shots: 9, seed: 7),
                       NextBlock.randomSpotSequence(spots: spots, shots: 9, seed: 7),
                       "a relaunch must not reshuffle a block that is half shot")
        XCTAssertNotEqual(NextBlock.randomSpotSequence(spots: spots, shots: 9, seed: 7),
                          NextBlock.randomSpotSequence(spots: spots, shots: 9, seed: 8))
        XCTAssertTrue(NextBlock.randomSpotSequence(spots: [], shots: 9, seed: 1).isEmpty)
        XCTAssertEqual(NextBlock.randomSpotSequence(spots: [.three], shots: 3, seed: 1), [.three, .three, .three])
    }

    /// The shuffled offer is one short **set** at each spot, in the app's order — not one shot at
    /// each. A recording is saved at one spot, so a block spanning four would have to label every
    /// shot in it with one of them, and that would be a number nobody measured.
    func testTheShuffledOfferIsOneSetPerSpotAndCarriesTheOrderItWasBuiltWith() {
        let last = NextBlock.LastBlock(role: .retention, spot: .freeThrow, countedShots: 10,
                                       measureValue: 0.119, measureN: 10, hasCheck: true, checkPassed: true)
        let d = NextBlock.decide(state(last: last, ladder: [.freeThrow, .elbow, .three],
                                       blocksDoneToday: 3, shotsToday: 40))
        guard let shuffled = d.alternatives.first(where: { $0.gameLike == .randomSpot }) else {
            return XCTFail("no shuffled block was offered")
        }
        XCTAssertEqual(shuffled.spotSequence.count, 3, "one entry per set, one set per spot")
        XCTAssertEqual(Set(shuffled.spotSequence), [.freeThrow, .elbow, .three])
        XCTAssertEqual(shuffled.spot, shuffled.spotSequence.first, "the offer starts at the first set's spot")
        XCTAssertGreaterThanOrEqual(shuffled.shots, 5, "a set is shots at one spot, not one shot")
        for spot in shuffled.spotSequence {
            XCTAssertTrue(shuffled.instruction.contains(spot.rawValue), shuffled.instruction)
        }
        XCTAssertTrue(shuffled.whatItBuys.contains("never mixed into one number"), shuffled.whatItBuys)
        // Every other variant carries no sequence: only the shuffled one is an order the app made.
        for plan in d.alternatives where plan.gameLike != .randomSpot {
            XCTAssertTrue(plan.spotSequence.isEmpty)
            XCTAssertEqual(plan.spot, .freeThrow, "every other condition is shot at the plan's spot")
        }
    }

    // MARK: The anti-repeat rule (2026-09-25)
    //
    // The complaint these are written from: the plan "kept giving me the same thing to do". Each of
    // the three stalling rows now changes its ask the second time, and any of them ends the day the
    // third time rather than asking a third time in the same words.

    /// The flat drill block, shot twice, does not come back a third time as the same cued set.
    private var flatDrill: NextBlock.LastBlock {
        NextBlock.LastBlock(role: .drill, spot: .freeThrow, countedShots: 26,
                            measureValue: 0.182, measureN: 26, hasCheck: true,
                            checkPassed: false, checkBaselineValue: 0.186, checkTarget: 0.126)
    }

    func testASecondFlatSetTakesTheCueAwayInsteadOfRepeating() {
        let first = NextBlock.decide(state(last: flatDrill))
        XCTAssertEqual(first.plan.reasonKey, .measureFlat)
        XCTAssertTrue(first.plan.cued)

        let second = NextBlock.decide(state(last: flatDrill, proposalsToday: [.measureFlat]))
        XCTAssertEqual(second.plan.reasonKey, .flatTwiceUncued)
        XCTAssertEqual(second.plan.role, .retention)
        XCTAssertFalse(second.plan.cued, "the point of the second block is that the cue is gone")
        XCTAssertEqual(second.plan.spot, .freeThrow)
        XCTAssertTrue(second.isToday, "it is still today's block, just a different one")
        XCTAssertNotEqual(second.plan.instruction, first.plan.instruction)
    }

    func testAThirdTimeEndsTheDayRatherThanAskingAgain() {
        let d = NextBlock.decide(state(last: flatDrill, proposalsToday: [.measureFlat, .measureFlat]))
        XCTAssertFalse(d.isToday, "the third identical ask becomes tomorrow's first block")
        XCTAssertTrue(d.dayDoneReason?.contains("twice today") == true, d.dayDoneReason ?? "")
        XCTAssertFalse(d.dayDoneReason?.contains("convention") == true,
                       "this is the repeat rule, not the day cap")
        XCTAssertTrue(d.alternatives.isEmpty || d.plan.gameLike == nil)
    }

    /// The way out of a loop cannot itself become a loop: once the un-cued block has been asked for,
    /// a flat cued set does not bring it back a second time — the day ends instead.
    func testTheEscalationIsNotOfferedTwiceInOneDay() {
        let d = NextBlock.decide(state(last: flatDrill,
                                       proposalsToday: [.measureFlat, .flatTwiceUncued, .retentionNotHeld]))
        XCTAssertFalse(d.isToday)
        XCTAssertTrue(d.dayDoneReason?.contains("twice today") == true, d.dayDoneReason ?? "")
    }

    func testTheSecondUnmeasurableBlockAsksForACameraChangeAndAShortSet() {
        let last = NextBlock.LastBlock(role: .drill, spot: .elbow, countedShots: 0,
                                       measureValue: nil, measureN: 0,
                                       measureUnavailableReason: "No shot in that block was measurable: the ring was out of frame.",
                                       hasCheck: true, checkPassed: nil)
        let first = NextBlock.decide(state(last: last))
        XCTAssertEqual(first.plan.reasonKey, .measureUnavailable)

        let second = NextBlock.decide(state(last: last, proposalsToday: [.measureUnavailable]))
        XCTAssertEqual(second.plan.reasonKey, .measureUnavailableAgain)
        XCTAssertLessThan(second.plan.shots, first.plan.shots, "a cheap set, to test the framing")
        XCTAssertTrue(second.plan.instruction.contains("phone"), second.plan.instruction)
        XCTAssertTrue(second.plan.reason.contains("twice"), second.plan.reason)
    }

    /// The first ask is the shortfall itself; the second is sized by the share of shots that counted,
    /// which is why the first one did not close the gap.
    func testTheSecondShortBlockIsSizedByTheShareOfShotsThatCounted() {
        let last = NextBlock.LastBlock(role: .drill, spot: .freeThrow, countedShots: 6,
                                       attemptedShots: 10,
                                       measureValue: 0.19, measureN: 6, hasCheck: true,
                                       checkPassed: nil)
        let first = NextBlock.decide(state(last: last))
        XCTAssertEqual(first.plan.reasonKey, .notEnoughShots)
        XCTAssertEqual(first.plan.shots, 20, "the shortfall to the floor of 25, rounded up to five")

        let second = NextBlock.decide(state(last: last, proposalsToday: [.notEnoughShots]))
        XCTAssertEqual(second.plan.reasonKey, .notEnoughShotsBigger)
        // 19 more counted shots at 6-in-10 is about 32, rounded up to 35, clipped to the 30 ArcLab
        // will ask for in one block.
        XCTAssertEqual(second.plan.shots, 30)
        XCTAssertGreaterThan(second.plan.shots, first.plan.shots)
        XCTAssertTrue(second.plan.whatItBuys.contains("6 of 10 shots counted"), second.plan.whatItBuys)
        XCTAssertTrue(second.plan.reason.contains("n = 6"), second.plan.reason)
        XCTAssertTrue(second.plan.reason.contains("not a fail"), second.plan.reason)
    }

    /// With no attempted count there is no share to scale by, so nothing is invented.
    func testTheSecondShortBlockScalesNothingWhenTheAttemptedCountIsUnknown() {
        let last = NextBlock.LastBlock(role: .drill, spot: .freeThrow, countedShots: 6,
                                       measureValue: 0.19, measureN: 6, hasCheck: true, checkPassed: nil)
        let d = NextBlock.decide(state(last: last, proposalsToday: [.notEnoughShots]))
        XCTAssertEqual(d.plan.shots, 20, "the shortfall, unscaled")
        XCTAssertFalse(d.plan.whatItBuys.contains("counted, so"), d.plan.whatItBuys)
    }

    /// A row that moves to a different spot every time is not a repeat, so the rule leaves it alone.
    func testTheRuleDoesNotEndTheDayOnARowThatIsMakingProgress() {
        let passed = NextBlock.LastBlock(role: .drill, spot: .freeThrow, countedShots: 26,
                                         measureValue: 0.11, measureN: 26, hasCheck: true,
                                         checkPassed: true, checkBaselineValue: 0.186, checkTarget: 0.126)
        let d = NextBlock.decide(state(last: passed, ladder: [.freeThrow, .elbow, .midRange],
                                       proposalsToday: [.ladderNextSpot, .ladderNextSpot]))
        XCTAssertEqual(d.plan.reasonKey, .ladderNextSpot)
        XCTAssertTrue(d.isToday)
    }

    /// The day cap is a stated convention, so the number it is set to is worth pinning.
    func testTheDayCapIsFiveBlocksOfTen() {
        XCTAssertEqual(NextBlock.Cap.default.blocks, 5)
        XCTAssertEqual(NextBlock.Cap.default.shots, 60)
    }

    // MARK: The ladder itself

    func testStepOutGoesOneSpotFartherAndStopsAtTheThree() {
        XCTAssertEqual(NextBlock.stepOut(from: .freeThrow), .elbow)
        XCTAssertEqual(NextBlock.stepOut(from: .midRange), .collegeThree)
        XCTAssertNil(NextBlock.stepOut(from: .three))
        XCTAssertNil(NextBlock.stepOut(from: .other))
    }
}
