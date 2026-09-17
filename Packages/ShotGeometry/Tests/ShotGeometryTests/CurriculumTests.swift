import XCTest
@testable import ShotGeometry

/// The curriculum's own gates (`docs/research/shooting-curriculum-2026-09-15.md`).
///
/// Three things are asserted, because three things could silently rot:
///  1. the teaching order is a real order — unique, contiguous, and every prerequisite earlier;
///  2. every claim carries a grade and a source, so nothing ships as an unattributed assertion;
///  3. every measurable gate names a measure the engine can actually read out of a diagnosis today,
///     and every gate that is *not* measurable says why instead of carrying a number.
final class CurriculumTests: XCTestCase {

    // MARK: A diagnosis with every readable measure present

    /// Two spots, enough shots each to clear `ShotDoctor.spotFloor` and the pass checks' minimums,
    /// with every trajectory field filled so `FixLibrary.value` has something to find. Values are
    /// spread deterministically; nothing here is a claim about a real shooter.
    private func fullDiagnosis(scale: Double = 1.0) -> Diagnosis {
        var records: [ShotRecord] = []
        let spots: [(DoctorSpot, Double, Double)] = [(.freeThrow, 7.2, 4.19), (.three, 8.1, 6.75)]
        var id = 0
        for (spot, speed, distance) in spots {
            for i in 0..<40 {
                // Deterministic alternating spread around the mean, widened by `scale`.
                let wobble = Double((i % 5) - 2) / 10.0 * scale
                records.append(ShotRecord(
                    id: id, sessionID: "s", sessionDate: Date(timeIntervalSince1970: 0), sequence: i,
                    spot: spot, outcome: i % 3 == 0 ? .make : .miss, accepted: true,
                    releaseSpeed: speed + wobble * 0.2,
                    releaseAngle: Angle.radians(50 + wobble),
                    releaseHeight: 2.2 + wobble * 0.02,
                    releaseDistance: distance,
                    entryAngle: Angle.radians(44 + wobble),
                    depthPastFrontRim: 0.26 + wobble * 0.05,
                    lateralDeviation: 0.01 + wobble * 0.02,
                    dipToRelease: 0.7 + wobble * 0.05,
                    viewClass: .side))
                id += 1
            }
        }
        return ShotDoctor.diagnose(records: records)
    }

    // MARK: 1 — the order is an order

    func testTeachingOrderIsUniqueAndContiguous() {
        let orders = Curriculum.modules.map(\.order).sorted()
        XCTAssertEqual(orders, Array(0..<Curriculum.modules.count),
                       "module orders must be 0..<n with no gaps and no duplicates")
        XCTAssertEqual(Set(Curriculum.modules.map(\.id)).count, Curriculum.modules.count,
                       "module ids must be unique")
        XCTAssertEqual(Set(Curriculum.modules.map(\.id)), Set(CurriculumModuleID.allCases),
                       "every CurriculumModuleID must appear in the catalogue exactly once")
        for id in CurriculumModuleID.allCases {
            XCTAssertEqual(Curriculum.module(id).id, id, "module(\(id)) must round-trip")
        }
    }

    func testPrerequisitesAreAcyclicAndPointBackwards() {
        let byID = Dictionary(uniqueKeysWithValues: Curriculum.modules.map { ($0.id, $0) })
        for m in Curriculum.modules {
            XCTAssertFalse(m.prerequisites.contains(m.id), "\(m.id) must not require itself")
            XCTAssertEqual(Set(m.prerequisites).count, m.prerequisites.count,
                           "\(m.id) lists a prerequisite twice")
            for p in m.prerequisites {
                guard let pre = byID[p] else { return XCTFail("\(m.id) requires unknown module \(p)") }
                XCTAssertLessThan(pre.order, m.order,
                                  "\(m.id) requires \(p), which must be taught earlier — a forward edge is a cycle waiting to happen")
            }
        }
        // A backwards-only edge set on a strict order cannot contain a cycle; assert the reachability
        // closure terminates anyway, so a future edge that breaks the rule above is caught twice.
        for m in Curriculum.modules {
            var seen: Set<CurriculumModuleID> = []
            var stack = m.prerequisites
            var steps = 0
            while let next = stack.popLast() {
                steps += 1
                XCTAssertLessThan(steps, 1000, "prerequisite walk from \(m.id) did not terminate")
                guard seen.insert(next).inserted else { continue }
                XCTAssertNotEqual(next, m.id, "\(m.id) is reachable from its own prerequisites — cycle")
                stack.append(contentsOf: byID[next]?.prerequisites ?? [])
            }
        }
    }

    func testAvailabilityFollowsPrerequisites() {
        let first = Curriculum.available(completed: [])
        XCTAssertEqual(first.map(\.id), [.base], "with nothing done, only the base module is open")
        XCTAssertTrue(Curriculum.isUnlocked(.base, completed: []))
        XCTAssertFalse(Curriculum.isUnlocked(.range, completed: [.base]))
        XCTAssertTrue(Curriculum.isUnlocked(.range, completed: [.base, .dipAndRhythm, .releaseAndFollowThrough]))
        let all = Set(CurriculumModuleID.allCases)
        XCTAssertEqual(Curriculum.available(completed: all).count, Curriculum.modules.count,
                       "with everything done, every module is open")
        XCTAssertEqual(Curriculum.available(completed: all).map(\.order), Array(0..<Curriculum.modules.count),
                       "availability comes back in teaching order")
    }

    // MARK: 2 — every claim has a grade and a source

    func testEveryClaimIsGradedAndSourced() {
        for m in Curriculum.modules {
            XCTAssertFalse(m.title.isEmpty, "\(m.id) needs a title")
            XCTAssertFalse(m.summary.isEmpty, "\(m.id) needs a summary")
            XCTAssertFalse(m.cue.isEmpty, "\(m.id) needs a cue")
            XCTAssertFalse(m.whatCoachWatches.isEmpty, "\(m.id) must say what the coach watches")
            XCTAssertFalse(m.drills.isEmpty, "\(m.id) needs at least one drill")
            XCTAssertFalse(m.doneWhen.isEmpty, "\(m.id) needs at least one 'done' check")
            XCTAssertFalse(m.faults.isEmpty, "\(m.id) needs at least one fault")

            for d in m.drills {
                XCTAssertFalse(d.source.isEmpty, "\(m.id)/\(d.drill.name): a drill with no source is an assertion")
                XCTAssertFalse(d.purpose.isEmpty, "\(m.id)/\(d.drill.name) needs a purpose")
                XCTAssertGreaterThan(d.drill.reps, 0, "\(m.id)/\(d.drill.name) needs reps")
                XCTAssertGreaterThan(d.drill.sets, 0, "\(m.id)/\(d.drill.name) needs sets")
                XCTAssertFalse(d.drill.constraint.isEmpty, "\(m.id)/\(d.drill.name) needs a constraint — otherwise it is shooting around")
                XCTAssertFalse(d.drill.schedule.isEmpty, "\(m.id)/\(d.drill.name) needs a practice schedule")
                XCTAssertTrue(ShotEvidenceGrade.allCases.contains(d.methodGrade))
            }
            for f in m.faults {
                XCTAssertFalse(f.name.isEmpty, "\(m.id): a fault needs a name")
                XCTAssertFalse(f.howItShowsInNumbers.isEmpty,
                               "\(m.id)/\(f.name): a fault must say how it shows in the numbers, even when the answer is 'it does not'")
                XCTAssertFalse(f.sources.isEmpty, "\(m.id)/\(f.name): a fault with no source is folklore in disguise")
                for s in f.sources { XCTAssertFalse(s.isEmpty) }
            }
            for c in m.doneWhen {
                XCTAssertFalse(c.plainWords.isEmpty, "\(m.id): a 'done' check needs plain words")
                XCTAssertFalse(c.source.isEmpty, "\(m.id)/\(c.plainWords): a gate with no source is a made-up target")
            }
        }
    }

    /// Folklore must be shipped labelled, not omitted. If the D-graded claims ever disappear the app
    /// has quietly started presenting coaching lore as silence, which is its own kind of dishonesty.
    func testFolkloreIsShippedAndLabelled() {
        let dGraded = Curriculum.modules.flatMap { m in m.faults.filter { $0.grade == .d }.map { (m.id, $0.name) } }
        XCTAssertGreaterThanOrEqual(dGraded.count, 6,
                                    "the folklore coaches actually teach is listed as grade D, not left out")
        let modulesWithFolklore = Set(dGraded.map(\.0))
        for id in [CurriculumModuleID.base, .footwork, .guideHand, .releaseAndFollowThrough, .range, .offTheDribble, .gameSpeed] {
            XCTAssertTrue(modulesWithFolklore.contains(id), "\(id) teaches at least one thing that is folklore; say so")
        }
        // A D-graded fault must never be wired to a scored hypothesis without the sentence admitting
        // what is actually being measured.
        for m in Curriculum.modules {
            for f in m.faults where f.grade == .d && f.hypothesis != nil {
                XCTAssertFalse(f.howItShowsInNumbers.isEmpty)
                XCTAssertFalse(f.sources.isEmpty)
            }
        }
    }

    // MARK: 3 — every gate names a metric that exists

    func testEveryDoneCheckIsEitherMeasurableOrExplained() {
        for m in Curriculum.modules {
            for c in m.doneWhen {
                switch (c.check, c.unavailableReason) {
                case (.some, .some):
                    XCTFail("\(m.id)/\(c.plainWords): a gate cannot be both scored and unavailable")
                case (.none, .none):
                    XCTFail("\(m.id)/\(c.plainWords): a gate with no check must say why (CLAUDE.md rule 1)")
                case (.none, .some(let why)):
                    XCTAssertFalse(why.isEmpty, "\(m.id)/\(c.plainWords): the reason must not be empty")
                    XCTAssertFalse(c.isMeasurableToday)
                case (.some(let check), .none):
                    XCTAssertTrue(c.isMeasurableToday)
                    XCTAssertGreaterThan(check.minimumN, 0, "\(m.id)/\(c.plainWords): a gate needs a shot floor")
                    XCTAssertFalse(check.description.isEmpty)
                }
            }
        }
    }

    func testEveryMeasurableGateReadsARealNumber() {
        let d = fullDiagnosis()
        for m in Curriculum.modules {
            for c in m.doneWhen {
                guard let check = c.check else { continue }
                let read = FixLibrary.value(check.measure, d, spot: .freeThrow, scope: check.scope)
                XCTAssertNotNil(read,
                                "\(m.id)/\(c.plainWords) is gated on \(check.measure.rawValue) at scope \(check.scope.rawValue), which the engine cannot read out of a diagnosis — it must be an unavailableReason instead")
                if let read {
                    XCTAssertTrue(read.value.isFinite, "\(check.measure.rawValue) read back non-finite")
                    XCTAssertGreaterThan(read.n, 0)
                }
            }
        }
    }

    /// The gates are scored by exactly the machinery that scores a plan, so a module can be handed to
    /// the practice flow unchanged. Here: a session whose spread is deliberately wider must not pass a
    /// narrowing gate, and one whose spread is narrower must.
    func testGatesScoreThroughFixLibrary() {
        let wide = fullDiagnosis(scale: 2.0)
        let narrow = fullDiagnosis(scale: 0.5)
        let gate = Curriculum.releaseAndFollowThrough.doneWhen.first { $0.check?.measure == .releaseSpeedSD }
        guard let check = gate?.check else { return XCTFail("the release module lost its release-speed gate") }

        let improved = FixLibrary.check(check, baseline: wide, followUp: narrow, spot: .freeThrow)
        XCTAssertEqual(improved.passed, true, "a halved spread must pass a narrowing gate: \(improved.sentence)")
        let worsened = FixLibrary.check(check, baseline: narrow, followUp: wide, spot: .freeThrow)
        XCTAssertEqual(worsened.passed, false, "a doubled spread must not pass: \(worsened.sentence)")
    }

    /// `notWiderRatio` is the app's own arithmetic, not a number typed in from a coaching book. If
    /// `DoctorStats.detectableSDRatio` ever changes, this fails rather than drifting silently.
    func testNotWiderRatioIsTheAppsOwnArithmetic() {
        guard let ratio = DoctorStats.detectableSDRatio(n: 30) else { return XCTFail("no detectable ratio at n = 30") }
        XCTAssertEqual(Curriculum.notWiderRatio, ratio, accuracy: 0.005,
                       "the 'not distinguishably wider' gates must use exp(1.96/√30), the same floor the plans use")
    }

    func testDepthGatesUseThePublishedBand() {
        let band = Curriculum.depthBandCm
        XCTAssertEqual(band.low, ShotDoctor.publishedMakeDepthBand.low * 100, accuracy: 1e-9)
        XCTAssertEqual(band.high, ShotDoctor.publishedMakeDepthBand.high * 100, accuracy: 1e-9)
        for m in Curriculum.modules {
            for c in m.doneWhen {
                guard let check = c.check, check.measure == .depthMeanCm,
                      case .insideBand(let lo, let hi) = check.target else { continue }
                XCTAssertEqual(lo, band.low, accuracy: 1e-9, "\(m.id) invented its own depth band")
                XCTAssertEqual(hi, band.high, accuracy: 1e-9, "\(m.id) invented its own depth band")
            }
        }
    }

    // MARK: 4 — the link back to the shot doctor

    func testHypothesisLookupFindsTheEarliestModuleThatTeachesIt() {
        XCTAssertEqual(Curriculum.module(for: .speedVariability)?.id, .releaseAndFollowThrough)
        XCTAssertEqual(Curriculum.module(for: .flatArcGeometry)?.id, .releaseAndFollowThrough)
        XCTAssertEqual(Curriculum.module(for: .rangeStrengthLimit)?.id, .range)
        XCTAssertEqual(Curriculum.module(for: .lateralAimBias)?.id, .base)
        XCTAssertEqual(Curriculum.module(for: .headInstability)?.id, .base)
        XCTAssertEqual(Curriculum.module(for: .fatigueDrift)?.id, .gameSpeed)

        // Whatever a hypothesis maps to, the module must actually name it among its faults.
        for h in HypothesisID.allCases {
            guard let m = Curriculum.module(for: h) else { continue }
            XCTAssertTrue(m.faults.contains { $0.hypothesis == h },
                          "\(m.id) was returned for \(h.rawValue) without listing it as a fault")
        }
    }

    /// The curriculum does not have to cover every hypothesis, but the gap must be visible rather
    /// than discovered by a shooter tapping "Learn why" and getting nothing. This records which
    /// hypotheses have no module, so adding one is a deliberate act.
    func testHypothesisCoverageIsExplicit() {
        let uncovered = HypothesisID.allCases.filter { Curriculum.module(for: $0) == nil }.map(\.rawValue).sorted()
        XCTAssertEqual(uncovered, ["arcVersusTurnover", "releaseHeightDrift", "sequencingDistalDominant", "spinAxisTilt", "speedUndershoot"].sorted(),
                       "the set of hypotheses with no Learn module changed — update the curriculum or this list, deliberately")
    }

    func testHonestyRulesTravelWithTheCurriculum() {
        XCTAssertGreaterThanOrEqual(Curriculum.honestyRules.count, 4)
        for r in Curriculum.honestyRules { XCTAssertFalse(r.isEmpty) }
    }
}
