import XCTest
@testable import ShotGeometry

/// Copy lint for everything a shooter reads on a court.
///
/// On 2026-09-19 the complaint was "I went to the drills and some of the descriptions are hard to
/// follow. It's kind of nonsense right now." It was right: a gate read `next session's
/// crossing-depth SD at or below this session's ÷ the detectable ratio`, which is a statistic
/// standing where an instruction should be.
///
/// The fix is structural rather than editorial, so it cannot rot:
///  1. every drill answers the same five questions — Setup, Do this, What the app watches,
///     Done when, Why this works;
///  2. `Do this` is one short imperative sentence, because it is the line read at arm's length
///     with a ball in your hands;
///  3. none of those lines, and none of the gate sentences beside them, may use the words that
///     belong to the engine or to a statistics paper. The precise version is not deleted — it
///     moves to a `detail` field, which is the one place those words are allowed, and which the
///     UI shows on tap.
///
/// Nothing here changes a number. The constants, the checks and the sources are untouched; only
/// the words changed, and this test is what stops them changing back.
final class DrillCopyTests: XCTestCase {

    // MARK: The banned list

    /// `pattern` is a regular expression. Case matters for the acronyms (`SD` must not fire on the
    /// "sd" inside a word) and not for the rest.
    private struct Banned {
        let pattern: String
        let say: String
    }

    private static let banned: [Banned] = [
        Banned(pattern: "\\bSD\\b", say: "say \"spread\" — SD is a statistic, not something to do"),
        Banned(pattern: "\\bSDC\\b", say: "say \"more than luck can explain\""),
        Banned(pattern: "\\bICC\\b", say: "say how repeatable it is, in words"),
        Banned(pattern: "(?i)detectable ratio", say: "say the size of the change as a percentage, from Curriculum.narrowByPercent"),
        Banned(pattern: "(?i)crossing depth|crossing-depth", say: "say \"how far past the front of the ring your shots pass\""),
        Banned(pattern: "(?i)\\bbandwidth\\b", say: "say when you are told, and when you are not"),
        Banned(pattern: "(?i)\\bretention\\b|\\bretained\\b", say: "say \"still there next session\""),
        Banned(pattern: "(?i)\\bacquisition\\b", say: "say \"while the change is new\""),
        Banned(pattern: "(?i)\\bblocked\\b", say: "say \"one spot, every set\" or \"stay at one spot\""),
        // The same family, caught before it gets written: engine words and paper words that have a
        // plain English twin.
        Banned(pattern: "(?i)\\bvariance\\b", say: "say \"scatter\" or \"spread\""),
        Banned(pattern: "(?i)\\bkinematic", say: "say what moves, and where"),
        Banned(pattern: "(?i)proximal|distal\\b", say: "say \"legs\", \"shoulder\", \"wrist\""),
        Banned(pattern: "(?i)\\bsagittal\\b|\\bfrontal plane\\b", say: "say which way the phone is pointing"),
        Banned(pattern: "(?i)\\bstature\\b", say: "say \"your height\""),
        Banned(pattern: "(?i)\\bp-value\\b|\\bp < |\\bSMD\\b|ηp²", say: "a statistic belongs in `detail`, not on the court"),
    ]

    /// Every identifier the engine uses for a measure. None may appear in a sentence: rule 2 of the
    /// copy guide (`docs/IMPROVEMENTS-2026-09-16.md` §4) is "never show an identifier".
    private static let engineIdentifiers: [String] = PassMeasure.allCases.map(\.rawValue)

    // MARK: What gets linted

    /// One string a shooter can read, with enough of a label to find it again.
    private struct Line {
        let where_: String
        let text: String
    }

    /// The five plain lines of a drill, plus the two sentences that sit with them. `detail` is
    /// deliberately absent: it is the allowlisted field, and the whole point of it.
    private func lines(of d: Drill, at place: String) -> [Line] {
        [Line(where_: "\(place).name", text: d.name),
         Line(where_: "\(place).setup", text: d.setup),
         Line(where_: "\(place).doThis", text: d.doThis),
         Line(where_: "\(place).watches", text: d.watches),
         Line(where_: "\(place).doneWhen", text: d.doneWhen),
         Line(where_: "\(place).why", text: d.why),
         Line(where_: "\(place).constraint", text: d.constraint),
         Line(where_: "\(place).schedule", text: d.schedule)]
    }

    private func lines(of c: PassCheck, at place: String) -> [Line] {
        [Line(where_: "\(place).description", text: c.description)]
    }

    /// Everything the curriculum puts in front of a shooter.
    private func curriculumLines() -> [Line] {
        var out: [Line] = []
        for m in Curriculum.modules {
            let mid = m.id.rawValue
            out.append(Line(where_: "\(mid).cue", text: m.cue))
            out.append(contentsOf: m.whatCoachWatches.enumerated().map {
                Line(where_: "\(mid).whatCoachWatches[\($0.offset)]", text: $0.element)
            })
            out.append(contentsOf: m.openQuestions.enumerated().map {
                Line(where_: "\(mid).openQuestions[\($0.offset)]", text: $0.element)
            })
            for d in m.drills {
                out.append(contentsOf: lines(of: d.drill, at: "\(mid)/\(d.drill.name)"))
                out.append(Line(where_: "\(mid)/\(d.drill.name).purpose", text: d.purpose))
            }
            for c in m.doneWhen {
                let place = "\(mid) gate \"\(c.plainWords.prefix(40))…\""
                out.append(Line(where_: "\(place).plainWords", text: c.plainWords))
                if let why = c.unavailableReason {
                    out.append(Line(where_: "\(place).unavailableReason", text: why))
                }
                if let check = c.check { out.append(contentsOf: lines(of: check, at: place)) }
            }
            for f in m.faults {
                out.append(Line(where_: "\(mid)/fault \(f.name)", text: f.name))
                out.append(Line(where_: "\(mid)/fault \(f.name).howItShows", text: f.howItShowsInNumbers))
            }
        }
        return out
    }

    /// Everything a plan puts in front of a shooter.
    private func planLines() -> [Line] {
        var out: [Line] = []
        for id in HypothesisID.allCases {
            let p = FixLibrary.package(for: id)
            let place = id.rawValue
            out.append(Line(where_: "\(place).cue", text: p.cue))
            out.append(contentsOf: lines(of: p.drill, at: "\(place)/\(p.drill.name)"))
            out.append(Line(where_: "\(place).measureThatShouldMove", text: p.measureThatShouldMove))
            out.append(Line(where_: "\(place).expectedMagnitude", text: p.expectedMagnitude))
            out.append(Line(where_: "\(place).retentionRule", text: p.retentionRule))
            out.append(contentsOf: lines(of: p.passCheck, at: place))
            if let t = p.trialSuggestion {
                out.append(Line(where_: "\(place).trialSuggestion", text: t))
            }
        }
        return out
    }

    private var allLines: [Line] { curriculumLines() + planLines() }

    // MARK: 1 — no jargon where an instruction belongs

    func testNoJargonInAnythingReadOnACourt() {
        let lines = allLines
        XCTAssertGreaterThan(lines.count, 200, "the lint walked almost nothing — it has been disconnected")
        for line in lines {
            for b in Self.banned {
                if let r = line.text.range(of: b.pattern, options: [.regularExpression]) {
                    XCTFail("""
                        \(line.where_) uses \"\(line.text[r])\": \(b.say).
                        Full line: \(line.text)
                        If the precision is load-bearing, move it to the drill's or the check's \
                        `detail` — that field is exempt and the UI shows it on tap.
                        """)
                }
            }
        }
    }

    func testNoEngineIdentifierIsEverShown() {
        for line in allLines {
            for ident in Self.engineIdentifiers where line.text.contains(ident) {
                XCTFail("\(line.where_) shows the engine's identifier \"\(ident)\": name the measure the way a shooter would say it.")
            }
        }
    }

    /// The exemption is real: `detail` is where the exact wording lives, and it must not have been
    /// quietly emptied to get past the lint above.
    func testThePreciseVersionSurvivedInDetail() {
        var detailed = 0
        for m in Curriculum.modules {
            for d in m.drills where d.drill.hasPlainCard {
                XCTAssertNotNil(d.drill.detail, "\(m.id)/\(d.drill.name): the precise version must not be lost, only moved")
                if let t = d.drill.detail { XCTAssertFalse(t.isEmpty); detailed += 1 }
            }
            for c in m.doneWhen {
                XCTAssertNotNil(c.precise, "\(m.id): gate \"\(c.plainWords)\" has no precise version behind it")
            }
        }
        for id in HypothesisID.allCases {
            let p = FixLibrary.package(for: id)
            XCTAssertNotNil(p.passCheck.detail, "\(id.rawValue): the plan's gate has no precise version behind it")
        }
        XCTAssertGreaterThanOrEqual(detailed, 16, "every curriculum drill carries its own precise note")
    }

    // MARK: 2 — the structure is there, in every drill

    func testEveryDrillAnswersTheSameFiveQuestions() {
        var checked = 0
        for m in Curriculum.modules {
            for d in m.drills {
                assertCard(d.drill, at: "\(m.id.rawValue)/\(d.drill.name)")
                XCTAssertNotNil(d.card, "\(m.id)/\(d.drill.name) has no card to render")
                checked += 1
            }
        }
        for id in HypothesisID.allCases {
            let p = FixLibrary.package(for: id)
            // `releaseHeightDrift` ships a drill called "None" on purpose: there is no honest thing
            // to practise, and inventing five lines for it would be inventing a claim.
            guard p.drill.totalShots > 0 else {
                XCTAssertFalse(p.drill.hasPlainCard, "\(id.rawValue) has no shots, so it must not pretend to be a drill")
                continue
            }
            assertCard(p.drill, at: id.rawValue)
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 30, "the structure check walked too few drills")
    }

    private func assertCard(_ d: Drill, at place: String) {
        XCTAssertFalse(d.setup.isEmpty, "\(place): no Setup — say where to stand, where the phone goes, how many shots")
        XCTAssertFalse(d.doThis.isEmpty, "\(place): no Do this — say the one thing to do on every shot")
        XCTAssertFalse(d.watches.isEmpty, "\(place): no What the app watches")
        XCTAssertFalse(d.doneWhen.isEmpty, "\(place): no Done when")
        XCTAssertFalse(d.why.isEmpty, "\(place): no Why this works")
        XCTAssertNotNil(d.plainCard, "\(place): the five lines are there but the card did not build")

        // Do this is read at arm's length with a ball in your hands.
        let words = d.doThis.split(whereSeparator: \.isWhitespace).count
        XCTAssertLessThanOrEqual(words, 25, "\(place).doThis is \(words) words: one short instruction, not a paragraph — \(d.doThis)")
        XCTAssertTrue(d.doThis.hasSuffix("."), "\(place).doThis must be one finished sentence")
        XCTAssertEqual(d.doThis.filter { $0 == "." }.count, 1,
                       "\(place).doThis must be exactly one sentence — \(d.doThis)")
        XCTAssertEqual(d.doThis.first?.isUppercase, true, "\(place).doThis starts an instruction")

        // Setup is where you are, not what to do: it must not be an instruction in disguise.
        XCTAssertFalse(d.setup.isEmpty && !d.doThis.isEmpty)
    }

    // MARK: 3 — the numbers in the words are the numbers in the code

    /// "About 30 % tighter" is not a number someone liked the sound of: it is
    /// `1 − 1 / DoctorStats.detectableSDRatio(n: 30)`, the same arithmetic the gate itself runs. If
    /// the ratio ever moves, this fails rather than letting the words drift away from the check.
    func testThePercentagesInTheCopyAreTheAppsOwnArithmetic() {
        guard let ratio = DoctorStats.detectableSDRatio(n: 30) else { return XCTFail("no detectable ratio at n = 30") }
        XCTAssertEqual(Curriculum.notWiderRatio, ratio, accuracy: 0.005)
        XCTAssertEqual(Curriculum.narrowByPercent, Int(((1 - 1 / ratio) * 100).rounded()))
        XCTAssertEqual(Curriculum.widerByPercent, Int(((ratio - 1) * 100).rounded()))
        XCTAssertEqual(Curriculum.narrowByPercent, 30, "exp(1.96/√30) = 1.43, so narrowing to 1 ÷ 1.43 is 30 %")
        XCTAssertEqual(Curriculum.widerByPercent, 43, "…and widening to 1.43 × is 43 %")

        // Every sentence that quotes one of those percentages must quote the computed one.
        let narrow = "\(Curriculum.narrowByPercent) %"
        let wider = "\(Curriculum.widerByPercent) %"
        var quoted = 0
        for line in allLines where line.text.contains(narrow) || line.text.contains(wider) { quoted += 1 }
        XCTAssertGreaterThanOrEqual(quoted, 12,
                                    "the gates that used to say \"÷ the detectable ratio\" must say the percentage instead")
        // …and no line may quote a hand-typed ratio where the percentage belongs.
        for line in allLines {
            XCTAssertNil(line.text.range(of: "1\\.4(3)?×", options: [.regularExpression]),
                         "\(line.where_) quotes the raw ratio: say \(wider) wider instead — \(line.text)")
        }
    }

    // MARK: 4 — the gate a shooter reads is the gate the app runs

    /// A plain sentence is only worth having if it still describes the check underneath it. Every
    /// gate that lands inside a band must name both ends of that band in its own words.
    func testBandGatesNameTheirNumbers() {
        var checks: [(String, PassCheck)] = []
        for m in Curriculum.modules {
            for c in m.doneWhen { if let k = c.check { checks.append(("\(m.id.rawValue)", k)) } }
        }
        for id in HypothesisID.allCases { checks.append((id.rawValue, FixLibrary.package(for: id).passCheck)) }

        for (place, check) in checks {
            guard case .insideBand(let low, let high) = check.target else { continue }
            // The ratio band (0 … 1.43) is stated as a percentage; the ±3 cm band is stated as
            // "3 cm"; the angle band as "40°"; the depth band as "25 and 28 cm".
            switch check.measure {
            case .entryAngleMeanDegrees:
                XCTAssertTrue(check.description.contains("\(Int(low))°"),
                              "\(place): the gate says \(Int(low))° but the sentence does not — \(check.description)")
            case .depthMeanCm:
                XCTAssertTrue(check.description.contains("\(Int(low))") && check.description.contains("\(Int(high))"),
                              "\(place): the depth band is \(Int(low))–\(Int(high)) cm; the sentence must say so — \(check.description)")
            case .lateralMeanCm:
                XCTAssertTrue(check.description.contains("\(Int(high)) cm"),
                              "\(place): the gate allows \(Int(high)) cm either side; the sentence must say so — \(check.description)")
            case .releaseSpeedSDRatioAcrossDistance:
                XCTAssertTrue(check.description.contains("\(Curriculum.widerByPercent) %"),
                              "\(place): the ratio band must be stated as a percentage — \(check.description)")
            default:
                break
            }
        }
    }

    /// Every gate sentence is a description of a comparison, so it must not be empty, must not end
    /// mid-thought, and must not be so long that it stops being a sentence.
    func testGateSentencesAreSentences() {
        for line in allLines where line.where_.hasSuffix(".description") {
            XCTAssertFalse(line.text.isEmpty)
            let words = line.text.split(whereSeparator: \.isWhitespace).count
            XCTAssertLessThanOrEqual(words, 40, "\(line.where_) is \(words) words — the rest belongs in `detail`")
            XCTAssertEqual(line.text.first?.isUppercase, false,
                           "\(line.where_) is read after \"…done when\", so it starts lower case — \(line.text)")
        }
    }
}
