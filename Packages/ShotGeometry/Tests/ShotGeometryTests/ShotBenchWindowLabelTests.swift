// `PrecisionRecall.swift` / `ShotLabels.swift`: the shot/notShot/unsure ground-truth labels and the
// recall/precision arithmetic built from them (docs/footage-2026-09-13/window_labels.json). Built
// from synthetic scores/skipped/labels only — no cache files, no video.
import XCTest
@testable import ShotBenchKit

final class ShotBenchWindowLabelTests: XCTestCase {

    // MARK: - WindowLabelLoader

    func testLoaderReportsMissingForAbsentPath() {
        let r = WindowLabelLoader.load(path: "/tmp/does-not-exist-\(UUID().uuidString).json")
        XCTAssertEqual(r.status, "missing")
        XCTAssertNil(r.labels)
    }

    func testLoaderReportsUnreadableForMalformedFile() throws {
        let path = NSTemporaryDirectory() + "bad-window-labels-\(UUID().uuidString).json"
        try "{ not valid json".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let r = WindowLabelLoader.load(path: path)
        XCTAssertEqual(r.status, "unreadable")
        XCTAssertNil(r.labels)
    }

    func testLoaderReportsUnreadableForEmptyLabelsArray() throws {
        let path = NSTemporaryDirectory() + "empty-window-labels-\(UUID().uuidString).json"
        try #"{"note": "n", "labels": []}"#.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let r = WindowLabelLoader.load(path: path)
        XCTAssertEqual(r.status, "unreadable")
    }

    func testLoaderScoresAWellFormedFile() throws {
        let path = NSTemporaryDirectory() + "good-window-labels-\(UUID().uuidString).json"
        let json = """
        {"note": "test", "labels": [
          {"windowID": "IMG_0001@0000.0", "clip": "IMG_0001.mov", "label": "shot", "reason": null},
          {"windowID": "IMG_0001@0010.0", "clip": "IMG_0001.mov", "label": "notShot", "reason": "rebound"},
          {"windowID": "IMG_0001@0020.0", "clip": "IMG_0001.mov", "label": "unsure", "reason": "ball occluded"}
        ]}
        """
        try json.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let r = WindowLabelLoader.load(path: path)
        XCTAssertEqual(r.status, "scored")
        XCTAssertEqual(r.labels?.byWindowID.count, 3)
        XCTAssertEqual(r.labels?.byWindowID["IMG_0001@0000.0"]?.label, .shot)
        XCTAssertEqual(r.labels?.byWindowID["IMG_0001@0010.0"]?.label, .notShot)
        XCTAssertEqual(r.labels?.byWindowID["IMG_0001@0020.0"]?.label, .unsure)
    }

    // MARK: - WindowLabelScorer.summarize arithmetic

    func outcome(_ id: String, clip: String = "IMG_0001.mov", accepted: Bool, reason: String? = nil) -> LabeledOutcome {
        LabeledOutcome(windowID: id, clip: clip, accepted: accepted, refusalCategory: accepted ? nil : (reason ?? "other: x"))
    }

    func label(_ id: String, _ value: ShotLabelValue, clip: String = "IMG_0001.mov") -> (String, WindowLabelEntry) {
        (id, WindowLabelEntry(windowID: id, clip: clip, label: value, reason: nil))
    }

    func testRecallAndPrecisionOnAMixedSet() {
        // 4 real shots: 3 accepted, 1 refused (recall = 3/4).
        // 3 notShot windows: 1 accepted (a fabricated measurement), 2 correctly refused.
        // accepted total = 3 (shot) + 1 (notShot) = 4; accepted-with-definite-label = 4; accepted-shot = 3.
        // precision = 3/4.
        let outcomes = [
            outcome("s1", accepted: true), outcome("s2", accepted: true), outcome("s3", accepted: true),
            outcome("s4", accepted: false, reason: "gravity gate (> 8%)"),
            outcome("n1", accepted: true), // fabricated: accepted but not a shot
            outcome("n2", accepted: false, reason: "plausibility gate"),
            outcome("n3", accepted: false, reason: "plausibility gate"),
        ]
        let labels = Dictionary(uniqueKeysWithValues: [
            label("s1", .shot), label("s2", .shot), label("s3", .shot), label("s4", .shot),
            label("n1", .notShot), label("n2", .notShot), label("n3", .notShot),
        ])
        let g = WindowLabelScorer.summarize(outcomes, label: "overall", labels: labels)
        XCTAssertEqual(g.shotCount, 4)
        XCTAssertEqual(g.shotAccepted, 3)
        XCTAssertEqual(g.recall, 0.75)
        XCTAssertEqual(g.acceptedCount, 4)
        XCTAssertEqual(g.acceptedWithDefiniteLabel, 4)
        XCTAssertEqual(g.acceptedShot, 3)
        XCTAssertEqual(g.precision, 0.75)
        XCTAssertEqual(g.unsureCount, 0)
        XCTAssertEqual(g.noLabelCount, 0)
        // one refused shot, bucketed under its refusal reason
        XCTAssertEqual(g.refusalByLabel.shot.first(where: { $0.reason == "gravity gate (> 8%)" })?.count, 1)
        // two refused notShot windows, same bucket
        XCTAssertEqual(g.refusalByLabel.notShot.first(where: { $0.reason == "plausibility gate" })?.count, 2)
    }

    func testUnsureAndNoLabelWindowsAreExcludedFromBothFractions() {
        // A window accepted with no label at all, and one refused window labelled `unsure`, must
        // move neither recall nor precision — this is the whole point of `unsure`/no-label being
        // separate counts rather than folded into notShot.
        let outcomes = [
            outcome("s1", accepted: true),               // shot, accepted — recall/precision material
            outcome("u1", accepted: false, reason: "x"),  // unsure, refused
            outcome("u2", accepted: true),                // unsure, accepted — must NOT count toward precision
            outcome("x1", accepted: true),                // no label at all, accepted — must NOT count toward precision
        ]
        let labels = Dictionary(uniqueKeysWithValues: [
            label("s1", .shot), label("u1", .unsure), label("u2", .unsure),
        ])
        let g = WindowLabelScorer.summarize(outcomes, label: "overall", labels: labels)
        XCTAssertEqual(g.shotCount, 1)
        XCTAssertEqual(g.recall, 1.0)
        XCTAssertEqual(g.acceptedCount, 3)               // s1, u2, x1 all accepted
        XCTAssertEqual(g.acceptedWithDefiniteLabel, 1)   // only s1 — u2 and x1 excluded
        XCTAssertEqual(g.acceptedShot, 1)
        XCTAssertEqual(g.precision, 1.0)
        XCTAssertEqual(g.unsureCount, 2)
        XCTAssertEqual(g.noLabelCount, 1)
    }

    func testAllUnsureYieldsNilFractionsNotZero() {
        // Every window `unsure`: recall and precision must be nil (undefined), never 0 — a 0 would
        // misreport "no shots recovered" when in fact nothing could be scored at all.
        let outcomes = [outcome("u1", accepted: true), outcome("u2", accepted: false, reason: "x"), outcome("u3", accepted: true)]
        let labels = Dictionary(uniqueKeysWithValues: [label("u1", .unsure), label("u2", .unsure), label("u3", .unsure)])
        let g = WindowLabelScorer.summarize(outcomes, label: "overall", labels: labels)
        XCTAssertEqual(g.shotCount, 0)
        XCTAssertNil(g.recall)
        XCTAssertEqual(g.acceptedWithDefiniteLabel, 0)
        XCTAssertNil(g.precision)
        XCTAssertEqual(g.unsureCount, 3)
        XCTAssertEqual(g.acceptedCount, 2)  // still reported: 2 of the 3 unsure windows were accepted
    }

    func testSkippedWindowsCountAsNotAcceptedForRecall() {
        // A window a variant skips (never evaluates) is exactly as much a "thrown away shot" as one
        // it evaluates and refuses — `outcomes(scores:skipped:)` must fold both into one list.
        let scores = [WindowScore(windowID: "s1", clip: "IMG_0001.mov", spot: "elbow", accepted: false, refusalReason: "plausibility gate: x",
                                  gError: 0.01, rmsPx: 5, releaseHeight: nil, releaseSpeed: nil, releaseAngleDegrees: nil,
                                  releaseUnavailableReason: nil, entryAngleDegrees: nil, entryAngleUnavailableReason: nil,
                                  depthPastFrontRim: nil, sampleCount: nil, releaseTimeErrorMs: nil)]
        let skipped = [SkippedWindow(windowID: "s2", clip: "IMG_0001.mov", spot: "elbow", reason: "no known release distance for spot \"elbow\"")]
        let outcomes = WindowLabelScorer.outcomes(scores: scores, skipped: skipped)
        XCTAssertEqual(outcomes.count, 2)
        let labels = Dictionary(uniqueKeysWithValues: [label("s1", .shot), label("s2", .shot)])
        let g = WindowLabelScorer.summarize(outcomes, label: "overall", labels: labels)
        XCTAssertEqual(g.shotCount, 2)
        XCTAssertEqual(g.shotAccepted, 0)
        XCTAssertEqual(g.recall, 0.0)
        XCTAssertTrue(g.refusalByLabel.shot.contains { $0.reason.hasPrefix("skipped by variant") })
    }

    // MARK: - WindowLabelScorer.run (the "no labels" / "all unsure" integration cases the gate asks for)

    func testRunWithNoLabelFileReportsMissingStatusAndNoSummaries() {
        let r = WindowLabelScorer.run(scores: [], skipped: [], labelsPath: "/tmp/does-not-exist-\(UUID().uuidString).json")
        XCTAssertEqual(r.status, "missing")
        XCTAssertNil(r.overall)
        XCTAssertTrue(r.perClip.isEmpty)
    }

    func testRunWithAllUnsureLabelsStillScoresWithNilFractions() throws {
        let path = NSTemporaryDirectory() + "all-unsure-\(UUID().uuidString).json"
        let json = """
        {"note": "test", "labels": [
          {"windowID": "w1", "clip": "IMG_0001.mov", "label": "unsure", "reason": "blurry"},
          {"windowID": "w2", "clip": "IMG_0001.mov", "label": "unsure", "reason": "off camera"}
        ]}
        """
        try json.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let scores = [
            WindowScore(windowID: "w1", clip: "IMG_0001.mov", spot: "elbow", accepted: true, refusalReason: nil,
                       gError: 0.01, rmsPx: 5, releaseHeight: nil, releaseSpeed: nil, releaseAngleDegrees: nil,
                       releaseUnavailableReason: nil, entryAngleDegrees: nil, entryAngleUnavailableReason: nil,
                       depthPastFrontRim: nil, sampleCount: nil, releaseTimeErrorMs: nil),
            WindowScore(windowID: "w2", clip: "IMG_0001.mov", spot: "elbow", accepted: false, refusalReason: "gravity error 10.0% > 8%",
                       gError: 0.10, rmsPx: 5, releaseHeight: nil, releaseSpeed: nil, releaseAngleDegrees: nil,
                       releaseUnavailableReason: nil, entryAngleDegrees: nil, entryAngleUnavailableReason: nil,
                       depthPastFrontRim: nil, sampleCount: nil, releaseTimeErrorMs: nil),
        ]
        let r = WindowLabelScorer.run(scores: scores, skipped: [], labelsPath: path)
        XCTAssertEqual(r.status, "scored")
        XCTAssertNotNil(r.overall)
        XCTAssertNil(r.overall?.recall)
        XCTAssertNil(r.overall?.precision)
        XCTAssertEqual(r.overall?.unsureCount, 2)
        XCTAssertEqual(r.perClip.count, 1)
        XCTAssertEqual(r.perClip.first?.label, "IMG_0001.mov")
    }
}
