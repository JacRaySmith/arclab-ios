import XCTest
import simd
@testable import ShotGeometry
@testable import ShotBenchKit

/// The court solve on the real 2026-09-13 corpus, checked against things whose answers were already
/// known before any of this existed: the rulebook's rim height and free-throw distance, the lane's
/// own width, and the field note's "lens 1.2 m, camera on the right wing roughly 8 m off the shot
/// line". A pose that reproduces the court it was **not** fitted to is real; one that only improves
/// a bench number could be overfitting.
///
/// Nothing here reads the footage: the marks are literals in `CourtMarksCorpus0913` (copied from
/// `docs/footage-2026-09-13/court_marks_2026-09-13.json`) and the rim traces are the bundled
/// auto-found ones, exactly as the `courtAnchored` variant uses them.
final class CourtCorpusTests: XCTestCase {

    func testEveryMarkedClipSolves() throws {
        for clip in ["IMG_1764.mov", "IMG_1765.mov", "IMG_1766.mov"] {
            let cal = try XCTUnwrap(CourtMarksCorpus0913.courtCalibration(forClip: clip), "no court pose for \(clip)")
            XCTAssertGreaterThanOrEqual(cal.features.filter { $0.used }.count, 2, "\(clip): too few usable features")
            XCTAssertLessThan(cal.bearingSigma, Angle.radians(15), "\(clip): bearing σ")
        }
    }

    /// The numbers the solve was never given. Printed as a table so the research document can quote
    /// it, and asserted loosely enough that a *real* court is inside and a wrong one is not.
    func testRecoveredAgainstKnown() throws {
        var rows: [String] = []
        rows.append("| clip | bearing | σ | rim height (known 3.048 m) | FT distance (known 4.191 m) | lane half-width (known 1.829 m) | lens height (field note 1.2 m) | camera off the shot line (field note ≈ 8 m) |")
        rows.append("|---|---:|---:|---:|---:|---:|---:|---:|")
        for clip in ["IMG_1764.mov", "IMG_1765.mov", "IMG_1766.mov"] {
            let cal = try XCTUnwrap(CourtMarksCorpus0913.courtCalibration(forClip: clip))
            let marks = try XCTUnwrap(CourtMarksCorpus0913.marks(forClip: clip))
            let k = CourtMarksCorpus0913.referenceIntrinsics

            // Lane half-width: the bearing came from the lane lines' *direction* (their vanishing
            // point); their distance from the lane's centre line is not used anywhere in the solve,
            // so re-deriving it from the same marks is an independent check of the whole pose.
            var laneOffsets: [Double] = []
            for line in marks.lines where line.name.hasPrefix("laneLine") {
                var ys: [Double] = []
                for p in line.imagePoints {
                    guard let q = CourtCalibrator.floorIntersection(p, cal: cal, intrinsics: k) else { continue }
                    ys.append(cal.court(fromCamera: q).y)
                }
                if !ys.isEmpty { laneOffsets.append(abs(Stats.median(ys))) }
            }
            // Free-throw line: its marked points should land at court x = 4.191 m. Again, only its
            // *direction* entered the solve.
            var ftXs: [Double] = []
            if let ft = marks.lines.first(where: { $0.name == "freeThrowLine" }) {
                for p in ft.imagePoints {
                    guard let q = CourtCalibrator.floorIntersection(p, cal: cal, intrinsics: k) else { continue }
                    ftXs.append(cal.court(fromCamera: q).x)
                }
            }

            let cam = cal.checks.cameraCourtPosition
            func f(_ v: Double?, _ fmt: String = "%.2f m") -> String { v.map { String(format: fmt, $0) } ?? "—" }
            rows.append("| `\(clip)` | \(String(format: "%.1f°", Angle.degrees(cal.bearing))) | \(String(format: "%.1f°", Angle.degrees(cal.bearingSigma))) | "
                        + "\(f(cal.checks.rimHeightAboveFloor)) | "
                        + "\(f(cal.checks.freeThrowDistance)) [circle] / \(f(ftXs.isEmpty ? nil : Stats.median(ftXs))) [line] | "
                        + "\(f(laneOffsets.isEmpty ? nil : Stats.median(laneOffsets))) | "
                        + "\(f(cal.checks.cameraHeight)) | "
                        + "\(String(format: "%.2f m at %.0f°", cal.checks.cameraHorizontalDistance, cal.checks.cameraBearingDegrees)) |")

            // Assertions: loose bands that a real court passes and a wrong pose does not.
            if !ftXs.isEmpty {
                XCTAssertEqual(Stats.median(ftXs), CourtMarkings.freeThrowLineDistance, accuracy: 1.2,
                               "\(clip): the marked free-throw line should land near 4.191 m from the rim")
            }
            if !laneOffsets.isEmpty {
                XCTAssertEqual(Stats.median(laneOffsets), CourtMarkings.laneHalfWidth, accuracy: 0.9,
                               "\(clip): the marked lane side lines should land near ±1.829 m")
            }
            if let h = cal.checks.rimHeightAboveFloor {
                XCTAssertEqual(h, Court.rimHeight, accuracy: 1.0, "\(clip): rim height above the floor")
            }
            XCTAssertGreaterThan(cal.checks.cameraHorizontalDistance, 4, "\(clip): camera distance")
            XCTAssertLessThan(cal.checks.cameraHorizontalDistance, 15, "\(clip): camera distance")
        }
        print("\n=== court pose: recovered vs known (2026-09-13 corpus) ===")
        for r in rows { print(r) }

        // The measured shooter stance, per clip.
        print("\n| clip | stance pixel | court (x, y) m | distance to rim | range σ | azimuth σ | depression |")
        print("|---|---|---|---:|---:|---:|---:|")
        for clip in ["IMG_1764.mov", "IMG_1765.mov", "IMG_1766.mov"] {
            let px = CourtMarksCorpus0913.markedStancePixel[clip]!
            guard let s = CourtMarksCorpus0913.measuredStance(forClip: clip) else {
                print("| `\(clip)` | (\(Int(px.x)), \(Int(px.y))) | refused — floor intersection ill-conditioned | | | | |")
                continue
            }
            print(String(format: "| `%@` | (%d, %d) | (%.2f, %.2f) | %.2f m | ±%.2f m | ±%.2f° | %.1f° |",
                         clip, Int(px.x), Int(px.y), s.court.x, s.court.y, s.horizontalDistanceToRim,
                         s.rangeSigma, Angle.degrees(s.azimuthSigma), Angle.degrees(s.depressionAngle)))
        }
        print("")
    }

    /// Per-feature bearings and residuals — the audit trail the research document quotes.
    func testFeatureBreakdownIsReported() throws {
        print("\n=== per-feature contributions ===")
        for clip in ["IMG_1764.mov", "IMG_1765.mov", "IMG_1766.mov"] {
            let cal = try XCTUnwrap(CourtMarksCorpus0913.courtCalibration(forClip: clip))
            for f in cal.features {
                let bearing = f.bearing.map { String(format: "%.1f°", Angle.degrees($0)) } ?? "—"
                let sigma = f.bearingSigma.map { String(format: "%.2f°", Angle.degrees($0)) } ?? "—"
                let res = f.residualPx.map { String(format: "%.1f px", $0) } ?? "—"
                print("\(clip)  \(f.name)  used=\(f.used)  bearing=\(bearing)  σ=\(sigma)  residual=\(res)  — \(f.reason)")
                if f.used { XCTAssertNotNil(f.bearing) }
            }
            for w in cal.warnings where w.contains("court") || w.contains("bearing") { print("  warning: \(w)") }
        }
        print("")
    }

    /// The variant wires up: every clip in the corpus has marks, and a window from a clip without
    /// them is skipped with a stated reason rather than analysed with a guessed bearing.
    func testCourtAnchoredVariantSkipsUnmarkedClips() throws {
        let variant = try XCTUnwrap(Variant.named("courtAnchored"))
        let known = sampleWindow(clip: "IMG_1765.mov")
        switch variant.makeOptions(known, VariantContext()) {
        case .options(let o):
            let anchor = try XCTUnwrap(o.courtAnchor)
            XCTAssertFalse(anchor.azimuthWindows().isEmpty)
            XCTAssertNil(o.fixedAzimuth, "the court anchor must not masquerade as a fixed azimuth")
            XCTAssertFalse(o.azimuthByFixedGravity, "the court anchor replaces the free scan, it does not add to it")
        case .skip(let why):
            XCTFail("IMG_1765 should be court-anchored, skipped: \(why)")
        }
        let unknown = sampleWindow(clip: "IMG_9999.mov")
        switch variant.makeOptions(unknown, VariantContext()) {
        case .options: XCTFail("a clip with no court marks must be skipped, not guessed")
        case .skip(let why): XCTAssertTrue(why.contains("IMG_9999"), why)
        }
    }

    /// The anchor's azimuth windows are a small fraction of the circle — that is the whole claim.
    func testAnchorWindowsAreNarrow() throws {
        for clip in ["IMG_1764.mov", "IMG_1765.mov", "IMG_1766.mov"] {
            let anchor = try XCTUnwrap(CourtMarksCorpus0913.anchor(for: sampleWindow(clip: clip)))
            let windows = anchor.azimuthWindows()
            XCTAssertFalse(windows.isEmpty, clip)
            let covered = windows.reduce(0.0) { $0 + 2 * $1.halfWidth }
            XCTAssertLessThan(covered, 2 * Double.pi * 0.3, "\(clip): court anchoring must narrow the search, covered \(Angle.degrees(covered))°")
        }
    }

    private func sampleWindow(clip: String) -> CachedWindow {
        CachedWindow(windowID: "\(clip)@0000.0", clip: clip, spot: "freeThrow", samples: [],
                     rimBoundary: [], rimDiameterUsed: Court.rimInnerDiameter, width: 1920, height: 1080,
                     hfovDegrees: 64, timeScale: 4, measuredFPS: 30, fileStart: 0, fileEnd: 1,
                     releaseTimeOverride: nil, dumpedAt: "")
    }
}
