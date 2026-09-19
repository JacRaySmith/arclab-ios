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
                       cap: NextBlock.Cap = .default) -> NextBlock.State {
        NextBlock.State(last: last, hasPlan: hasPlan, hasBaseline: hasBaseline, planSpot: .freeThrow,
                        measureName: "release-speed spread (SD)", measureUnit: "m/s", measureDecimals: 3,
                        grade: .a, minimumN: 25, targetNarrowsSpread: true,
                        drillName: "One-spot depth band", drillReps: 10, drillLadder: ladder,
                        spotsDoneToday: spotsDoneToday, blocksDoneToday: blocksDoneToday,
                        shotsToday: shotsToday, spreadWidensWithDistance: spreadWidens,
                        cap: cap)
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

    // MARK: The ladder itself

    func testStepOutGoesOneSpotFartherAndStopsAtTheThree() {
        XCTAssertEqual(NextBlock.stepOut(from: .freeThrow), .elbow)
        XCTAssertEqual(NextBlock.stepOut(from: .midRange), .collegeThree)
        XCTAssertNil(NextBlock.stepOut(from: .three))
        XCTAssertNil(NextBlock.stepOut(from: .other))
    }
}
