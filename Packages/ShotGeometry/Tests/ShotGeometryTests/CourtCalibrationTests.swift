import XCTest
@testable import ShotGeometry

/// `CourtCalibration` — the second court feature that fixes the camera's **bearing**, the one pose
/// parameter a rim ellipse plus gravity cannot supply (a circle is symmetric about its own axis).
///
/// Every test here builds a synthetic court with a *known* camera pose, projects the court's paint
/// through a pinhole, calibrates the rim exactly the way the app does (`RimCalibrator` on the
/// projected rim circle, no shortcuts), and then asks the solver to recover the bearing it was
/// never told. The refusals get the same treatment: a feature that genuinely cannot fix the bearing
/// must come back refused with a reason, not silently down-weighted into a plausible-looking pose.
final class CourtCalibrationTests: XCTestCase {

    // MARK: - a synthetic court

    /// World frame of these tests: origin on the floor directly below the rim centre, +x from the
    /// rim toward the free-throw line, +y = z × x, +z up. That is exactly the court frame
    /// `CourtCalibration` reports, so "recovered == truth" is a direct comparison.
    struct SyntheticCourt {
        var intrinsics: CameraIntrinsics
        var pose: CameraPose                       // world → camera
        var cameraCourtPosition: SIMD3<Double>

        func camera(_ p: SIMD3<Double>) -> SIMD3<Double> { pose.toCamera(p) }

        func pixel(_ p: SIMD3<Double>) -> SIMD2<Double>? {
            let c = camera(p)
            guard c.z > 1e-6 else { return nil }
            return intrinsics.pixel(fromNormalized: SIMD2(c.x / c.z, c.y / c.z))
        }

        /// Court +x, +y, +z expressed in the camera frame — the truth the solver must reproduce.
        var xAxisCamera: SIMD3<Double> { pose.rotate(SIMD3(1, 0, 0)) }
        var yAxisCamera: SIMD3<Double> { pose.rotate(SIMD3(0, 1, 0)) }
        var zAxisCamera: SIMD3<Double> { pose.rotate(SIMD3(0, 0, 1)) }
    }

    /// A camera standing at court position `(x, y, height)`, aimed at a point on the rim's axis.
    func court(cameraAt position: SIMD3<Double>, lookAtHeight: Double = 2.0,
               hfov: Double = 64, noisePx: Double = 0) -> SyntheticCourt {
        let k = CameraIntrinsics(width: 1920, height: 1080, horizontalFOVDegrees: hfov)
        let pose = CameraPose.lookAt(from: position, at: SIMD3(0, 0, lookAtHeight), worldUp: SIMD3(0, 0, 1))
        _ = noisePx
        return SyntheticCourt(intrinsics: k, pose: pose, cameraCourtPosition: position)
    }

    /// The rim as the app sees it: project the real ring circle and run the real calibrator.
    func rimCalibration(_ c: SyntheticCourt) throws -> RimCalibration {
        var pts: [SIMD2<Double>] = []
        for i in 0..<64 {
            let t = 2 * Double.pi * Double(i) / 64
            let p = SIMD3(Court.rimInnerRadius * cos(t), Court.rimInnerRadius * sin(t), Court.rimHeight)
            if let px = c.pixel(p) { pts.append(px) }
        }
        var o = RimCalibrationOptions()
        o.plausibleCameraHeight = nil
        return try RimCalibrator.calibrate(boundaryPoints: pts, intrinsics: c.intrinsics, options: o)
    }

    func laneLine(_ c: SyntheticCourt, side: Double, name: String, from x0: Double = 0.2, to x1: Double = 4.191) -> CourtLineMark {
        var pts: [SIMD2<Double>] = []
        for k in 0...5 {
            let x = x0 + (x1 - x0) * Double(k) / 5
            if let px = c.pixel(SIMD3(x, side * CourtMarkings.laneHalfWidth, 0)) { pts.append(px) }
        }
        return CourtLineMark(name: name, imagePoints: pts, courtDirection: SIMD3(1, 0, 0))
    }

    func freeThrowLine(_ c: SyntheticCourt) -> CourtLineMark {
        var pts: [SIMD2<Double>] = []
        for k in 0...5 {
            let y = -CourtMarkings.laneHalfWidth + 2 * CourtMarkings.laneHalfWidth * Double(k) / 5
            if let px = c.pixel(SIMD3(CourtMarkings.freeThrowLineDistance, y, 0)) { pts.append(px) }
        }
        return CourtLineMark(name: "freeThrowLine", imagePoints: pts, courtDirection: SIMD3(0, 1, 0),
                             courtPointOnLine: SIMD3(CourtMarkings.freeThrowLineDistance, 0, 0))
    }

    func freeThrowCircle(_ c: SyntheticCourt, points: Int = 16) -> CourtCircleMark {
        var pts: [SIMD2<Double>] = []
        for k in 0..<points {
            let t = 2 * Double.pi * Double(k) / Double(points)
            let p = SIMD3(CourtMarkings.freeThrowLineDistance + CourtMarkings.freeThrowCircleRadius * cos(t),
                          CourtMarkings.freeThrowCircleRadius * sin(t), 0)
            if let px = c.pixel(p) { pts.append(px) }
        }
        return CourtCircleMark(name: "freeThrowCircle", imagePoints: pts,
                               courtCenter: CourtMarkings.freeThrowCircleCenter,
                               radius: CourtMarkings.freeThrowCircleRadius)
    }

    func degreesBetween(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { Angle.degrees(angleBetween(a, b)) }

    // MARK: - the pose the rim cannot give

    func testSyntheticCourtRecoversKnownPose() throws {
        // Camera on the right wing, 8 m off the shot line, lens 1.2 m — the 2026-09-13 field note.
        let truthPosition = SIMD3<Double>(4.0, -8.0, 1.2)
        let c = court(cameraAt: truthPosition)
        let rim = try rimCalibration(c)
        let marks = CourtMarks(lines: [freeThrowLine(c), laneLine(c, side: 1, name: "laneLeft"), laneLine(c, side: -1, name: "laneRight")],
                               circles: [freeThrowCircle(c)], provenance: "synthetic")
        let cal = try CourtCalibrator.solve(rim: rim, marks: marks, intrinsics: c.intrinsics)

        XCTAssertLessThan(degreesBetween(cal.xAxis, c.xAxisCamera), 0.5, "court +x recovered")
        XCTAssertLessThan(degreesBetween(cal.yAxis, c.yAxisCamera), 0.5, "court +y recovered")
        XCTAssertLessThan(degreesBetween(cal.zAxis, c.zAxisCamera), 0.5, "court +z is gravity")

        // The camera's own court position, which nothing in the solve was told.
        let recovered = cal.checks.cameraCourtPosition
        XCTAssertEqual(recovered.x, truthPosition.x, accuracy: 0.25)
        XCTAssertEqual(recovered.y, truthPosition.y, accuracy: 0.25)
        XCTAssertEqual(recovered.z, truthPosition.z, accuracy: 0.15)

        // The scale checks come from the free-throw circle's own range, not from the rim.
        XCTAssertEqual(try XCTUnwrap(cal.checks.rimHeightAboveFloor), Court.rimHeight, accuracy: 0.12)
        XCTAssertEqual(try XCTUnwrap(cal.checks.freeThrowDistance), CourtMarkings.freeThrowLineDistance, accuracy: 0.15)

        // Every feature was used and reprojects onto its own marks.
        XCTAssertEqual(cal.features.filter { $0.used }.count, 4,
                       cal.features.map { "\($0.name): used=\($0.used) \($0.reason)" }.joined(separator: " | "))
        for f in cal.features where f.residualPx != nil {
            XCTAssertLessThan(f.residualPx!, 3.0, "\(f.name) reprojection")
        }
    }

    /// One feature is enough. Each kind, alone, must recover the same bearing.
    func testEachFeatureAloneFixesTheBearing() throws {
        let c = court(cameraAt: SIMD3(3.0, -7.5, 1.3))
        let rim = try rimCalibration(c)
        let all: [(String, CourtMarks)] = [
            ("free-throw line", CourtMarks(lines: [freeThrowLine(c)])),
            ("lane side line", CourtMarks(lines: [laneLine(c, side: 1, name: "laneLeft")])),
            ("free-throw circle", CourtMarks(circles: [freeThrowCircle(c)])),
            ("lane corner point", CourtMarks(points: [CourtPointMark(name: "laneCorner",
                                                                    imagePoint: try XCTUnwrap(c.pixel(SIMD3(CourtMarkings.freeThrowLineDistance, CourtMarkings.laneHalfWidth, 0))),
                                                                    courtPoint: SIMD3(CourtMarkings.freeThrowLineDistance, CourtMarkings.laneHalfWidth, 0))])),
        ]
        for (name, marks) in all {
            let cal = try CourtCalibrator.solve(rim: rim, marks: marks, intrinsics: c.intrinsics)
            XCTAssertLessThan(degreesBetween(cal.xAxis, c.xAxisCamera), 1.5, "\(name) alone")
        }
    }

    /// More features must not be worse than one: the combined σ is at most the best single feature's.
    func testMoreFeaturesOverDetermineThePose() throws {
        let c = court(cameraAt: SIMD3(4.0, -8.0, 1.2))
        let rim = try rimCalibration(c)
        let one = try CourtCalibrator.solve(rim: rim, marks: CourtMarks(lines: [laneLine(c, side: 1, name: "laneLeft")]), intrinsics: c.intrinsics)
        let many = try CourtCalibrator.solve(rim: rim,
                                             marks: CourtMarks(lines: [freeThrowLine(c), laneLine(c, side: 1, name: "laneLeft"), laneLine(c, side: -1, name: "laneRight")],
                                                               circles: [freeThrowCircle(c)]),
                                             intrinsics: c.intrinsics)
        XCTAssertLessThanOrEqual(many.bearingSigma, one.bearingSigma + 1e-9)
        XCTAssertEqual(many.features.count, 4)
    }

    // MARK: - refusals

    func testNoFeaturesRefused() throws {
        let c = court(cameraAt: SIMD3(4.0, -8.0, 1.2))
        let rim = try rimCalibration(c)
        XCTAssertThrowsError(try CourtCalibrator.solve(rim: rim, marks: CourtMarks(), intrinsics: c.intrinsics)) { e in
            guard case CourtCalibrationError.noFeatures = e else { return XCTFail("wrong error: \(e)") }
            XCTAssertTrue("\(e)".contains("symmetric"))
        }
    }

    /// A line parallel to the rim axis — a pole, the backboard's own edge — has a vanishing point
    /// fixed by gravity alone. It says nothing about the bearing and must be refused, not used.
    func testVerticalLineRefused() throws {
        let c = court(cameraAt: SIMD3(4.0, -8.0, 1.2))
        let rim = try rimCalibration(c)
        var pts: [SIMD2<Double>] = []
        for k in 0...5 {
            if let px = c.pixel(SIMD3(1.0, 2.0, 0.4 * Double(k))) { pts.append(px) }
        }
        let vertical = CourtLineMark(name: "poleEdge", imagePoints: pts, courtDirection: SIMD3(0, 0, 1))
        XCTAssertThrowsError(try CourtCalibrator.solve(rim: rim, marks: CourtMarks(lines: [vertical]), intrinsics: c.intrinsics)) { e in
            guard case CourtCalibrationError.noUsableFeature(let reasons) = e else { return XCTFail("wrong error: \(e)") }
            XCTAssertTrue(reasons.joined().contains("parallel to the rim axis"), reasons.joined())
        }
    }

    /// The three-point arc is a circle centred on the rim axis. It fixes the scale beautifully and
    /// the bearing not at all, because rotating the court about that axis maps it onto itself.
    func testCircleConcentricWithTheRimAxisRefusedForBearing() throws {
        let c = court(cameraAt: SIMD3(4.0, -8.0, 1.2))
        let rim = try rimCalibration(c)
        var pts: [SIMD2<Double>] = []
        for k in 0..<24 {
            let t = -1.1 + 2.2 * Double(k) / 23
            if let px = c.pixel(SIMD3(6.75 * cos(t), 6.75 * sin(t), 0)) { pts.append(px) }
        }
        let arc = CourtCircleMark(name: "threePointArc", imagePoints: pts, courtCenter: SIMD2(0, 0), radius: 6.75)
        XCTAssertThrowsError(try CourtCalibrator.solve(rim: rim, marks: CourtMarks(circles: [arc]), intrinsics: c.intrinsics)) { e in
            guard case CourtCalibrationError.noUsableFeature(let reasons) = e else { return XCTFail("wrong error: \(e)") }
            XCTAssertTrue(reasons.joined().contains("concentric with the rim axis"), reasons.joined())
        }
        // …but it still carries the scale, so it is not useless: paired with a bearing feature the
        // checks come back from it.
        let cal = try CourtCalibrator.solve(rim: rim, marks: CourtMarks(lines: [laneLine(c, side: 1, name: "laneLeft")], circles: [arc]),
                                            intrinsics: c.intrinsics)
        XCTAssertEqual(try XCTUnwrap(cal.checks.rimHeightAboveFloor), Court.rimHeight, accuracy: 0.2)
        XCTAssertFalse(cal.features.first { $0.name == "threePointArc" }!.used)
    }

    /// A short line whose image runs along the horizon: its vanishing point runs off to infinity
    /// and a pixel of marking error swings the bearing a long way. Refuse it on σ.
    func testFrontoParallelLineRefusedOnSigma() throws {
        // Camera on the lane's centre line, looking straight up it: a lane *side* line then runs
        // exactly across the view, so its image is parallel to the horizon.
        let c = court(cameraAt: SIMD3(0.0, -9.0, 1.2))
        let rim = try rimCalibration(c)
        var lane = laneLine(c, side: 1, name: "laneLeft")
        lane.imagePoints = Array(lane.imagePoints.prefix(2))      // a short trace: two points, small span
        let up = unit(rim.up)
        var options = CourtCalibrationOptions()
        options.markSigmaPx = 4
        let result = CourtCalibrator.bearingFromLine(lane, up: up, origin: rim.rimCenter - Court.rimHeight * up,
                                                     intrinsics: c.intrinsics, options: options)
        XCTAssertFalse(result.used, "an ill-conditioned line must not be used: \(result.reason)")
        XCTAssertTrue(result.reason.contains("fronto-parallel"), result.reason)
    }

    /// Only lines marked, and a camera standing square across the lane: the ±180° branch a
    /// direction-only feature leaves cannot be resolved, so refuse rather than pick a side. Adding
    /// one circle — an *absolute* feature — resolves it.
    func testBearingBranchAmbiguityRefusedAndFixedByACircle() throws {
        let c = court(cameraAt: SIMD3(0.0, -9.0, 1.2))
        let rim = try rimCalibration(c)
        let linesOnly = CourtMarks(lines: [freeThrowLine(c), laneLine(c, side: 1, name: "laneLeft")])
        XCTAssertThrowsError(try CourtCalibrator.solve(rim: rim, marks: linesOnly, intrinsics: c.intrinsics)) { e in
            guard case CourtCalibrationError.bearingBranchAmbiguous(let off) = e else { return XCTFail("wrong error: \(e)") }
            XCTAssertLessThan(off, 8)
            XCTAssertTrue("\(e)".contains("Mark a circle"))
        }
        var withCircle = linesOnly
        withCircle.circles = [freeThrowCircle(c)]
        let cal = try CourtCalibrator.solve(rim: rim, marks: withCircle, intrinsics: c.intrinsics)
        XCTAssertLessThan(degreesBetween(cal.xAxis, c.xAxisCamera), 2.0)
    }

    func testFeaturesThatDisagreeAreRefused() throws {
        let c = court(cameraAt: SIMD3(4.0, -8.0, 1.2))
        let rim = try rimCalibration(c)
        var wrong = laneLine(c, side: 1, name: "mislabelled")
        wrong.courtDirection = SIMD3(cos(0.9), sin(0.9), 0)     // the same paint, claimed 51.6° off
        XCTAssertThrowsError(try CourtCalibrator.solve(rim: rim,
                                                       marks: CourtMarks(lines: [freeThrowLine(c), wrong]),
                                                       intrinsics: c.intrinsics)) { e in
            guard case CourtCalibrationError.featuresDisagree(let spread, _, _) = e else { return XCTFail("wrong error: \(e)") }
            XCTAssertGreaterThan(spread, 25)
        }
    }

    func testTooFewPointsRefused() throws {
        let c = court(cameraAt: SIMD3(4.0, -8.0, 1.2))
        let rim = try rimCalibration(c)
        var thin = freeThrowCircle(c)
        thin.imagePoints = Array(thin.imagePoints.prefix(4))
        XCTAssertThrowsError(try CourtCalibrator.solve(rim: rim, marks: CourtMarks(circles: [thin]), intrinsics: c.intrinsics)) { e in
            guard case CourtCalibrationError.noUsableFeature(let reasons) = e else { return XCTFail("wrong error: \(e)") }
            XCTAssertTrue(reasons.joined().contains("≥ 6 traced points"), reasons.joined())
        }
    }

    // MARK: - the shooter as a measurement

    /// The floor intersection measures a shooter's **bearing** well and their **distance** badly,
    /// and the badness grows as L²/h. Pin both halves of that, because the whole value of the
    /// measurement depends on knowing which half to trust.
    func testFloorPointUncertaintyGrowsWithDistanceAndFallsWithCameraHeight() throws {
        let c = court(cameraAt: SIMD3(4.0, -8.0, 1.2))
        let rim = try rimCalibration(c)
        let cal = try CourtCalibrator.solve(rim: rim, marks: CourtMarks(lines: [freeThrowLine(c), laneLine(c, side: 1, name: "laneLeft")],
                                                                        circles: [freeThrowCircle(c)]),
                                            intrinsics: c.intrinsics)
        // Conditioning depends on the distance *from the camera*, so walk the point away along the
        // camera's own sightline (it stays on the floor either way).
        var previousRange = 0.0
        for distanceFromCamera in [4.0, 7.0, 10.0] {
            let feet = SIMD3(4.0, -8.0 + distanceFromCamera, 0.0)
            let px = try XCTUnwrap(c.pixel(feet))
            let p = try CourtCalibrator.floorPoint(px, calibration: cal, intrinsics: c.intrinsics,
                                                   pixelSigma: 4, maximumRangeSigma: 5)
            XCTAssertEqual(p.court.x, feet.x, accuracy: 0.25, "recovered standing position at \(distanceFromCamera) m")
            XCTAssertEqual(p.court.y, feet.y, accuracy: 0.25)
            XCTAssertGreaterThan(p.rangeSigma, previousRange, "range σ must grow with distance from the camera")
            previousRange = p.rangeSigma
            // Across the line of sight the same pixel error costs an order of magnitude less.
            XCTAssertLessThan(p.lateralSigma, p.rangeSigma)
        }
        // A higher camera measures the same shooter's distance better. (2.2 m, not 3 m: at rim
        // height the rim ellipse itself goes edge-on and there is no calibration at all.)
        let high = court(cameraAt: SIMD3(4.0, -8.0, 2.2))
        let highRim = try rimCalibration(high)
        let highCal = try CourtCalibrator.solve(rim: highRim, marks: CourtMarks(lines: [freeThrowLine(high), laneLine(high, side: 1, name: "laneLeft")]),
                                                intrinsics: high.intrinsics)
        let far = SIMD3(4.0, 2.0, 0.0)
        let lowP = try CourtCalibrator.floorPoint(try XCTUnwrap(c.pixel(far)), calibration: cal, intrinsics: c.intrinsics,
                                                  pixelSigma: 4, maximumRangeSigma: 5)
        let highP = try CourtCalibrator.floorPoint(try XCTUnwrap(high.pixel(far)), calibration: highCal, intrinsics: high.intrinsics,
                                                   pixelSigma: 4, maximumRangeSigma: 5)
        XCTAssertLessThan(highP.rangeSigma, lowP.rangeSigma)
    }

    func testFloorPointRefusedWhenIllConditioned() throws {
        let c = court(cameraAt: SIMD3(4.0, -8.0, 1.2))
        let rim = try rimCalibration(c)
        let cal = try CourtCalibrator.solve(rim: rim, marks: CourtMarks(lines: [freeThrowLine(c), laneLine(c, side: 1, name: "laneLeft")]),
                                            intrinsics: c.intrinsics)
        let veryFar = try XCTUnwrap(c.pixel(SIMD3(4.0, 6.0, 0)))        // 14 m from the camera
        let measured = try CourtCalibrator.floorPoint(veryFar, calibration: cal, intrinsics: c.intrinsics,
                                                      pixelSigma: 4, maximumRangeSigma: 10)
        XCTAssertGreaterThan(measured.rangeSigma, 0.2, "a 14 m floor intersection from a 1.2 m lens is soft")
        XCTAssertFalse(measured.warnings.isEmpty, "a soft distance must say so")
        XCTAssertThrowsError(try CourtCalibrator.floorPoint(veryFar, calibration: cal, intrinsics: c.intrinsics,
                                                            pixelSigma: 4, maximumRangeSigma: measured.rangeSigma / 2)) { e in
            guard case CourtCalibrationError.floorIntersectionIllConditioned(let sigma, _, _) = e else { return XCTFail("wrong error: \(e)") }
            XCTAssertEqual(sigma, measured.rangeSigma, accuracy: 1e-9)
        }
    }

    func testRayAboveHorizonRefused() throws {
        let c = court(cameraAt: SIMD3(4.0, -8.0, 1.2))
        let rim = try rimCalibration(c)
        let cal = try CourtCalibrator.solve(rim: rim, marks: CourtMarks(lines: [freeThrowLine(c), laneLine(c, side: 1, name: "laneLeft")]),
                                            intrinsics: c.intrinsics)
        let sky = SIMD2<Double>(960, 10)
        XCTAssertThrowsError(try CourtCalibrator.floorPoint(sky, calibration: cal, intrinsics: c.intrinsics)) { e in
            guard case CourtCalibrationError.rayAboveHorizon = e else { return XCTFail("wrong error: \(e)") }
        }
    }

    /// The measured standing position must produce the shot-plane azimuth that actually contains
    /// the shooter and the rim — the number the whole experiment turns on.
    func testMeasuredStanceGivesTheShotPlaneAzimuth() throws {
        let c = court(cameraAt: SIMD3(4.0, -8.0, 1.2))
        let rim = try rimCalibration(c)
        let cal = try CourtCalibrator.solve(rim: rim, marks: CourtMarks(lines: [freeThrowLine(c), laneLine(c, side: 1, name: "laneLeft")],
                                                                        circles: [freeThrowCircle(c)]),
                                            intrinsics: c.intrinsics)
        let feet = SIMD3(4.191, 1.2, 0.0)
        let p = try CourtCalibrator.floorPoint(try XCTUnwrap(c.pixel(feet)), calibration: cal, intrinsics: c.intrinsics,
                                               pixelSigma: 3, maximumRangeSigma: 2)
        let azimuth = try XCTUnwrap(p.shotPlaneAzimuth)
        let frame = ShotPlaneSolver.frame(calibration: rim, azimuth: azimuth)
        // The shooter's release point, 2.4 m above those feet, must lie in that plane.
        let release = cal.camera(fromCourt: SIMD3(feet.x, feet.y, 2.4))
        XCTAssertLessThan(abs(dot3(release - frame.origin, frame.normal)), 0.15, "release point off the solved shot plane")
    }

    // MARK: - the defaulted-off option

    /// `allowedAzimuths: nil` must leave `solveByFixedGravity` exactly as it was, and a window that
    /// covers the whole circle must give the same answer as no window at all.
    func testAzimuthWindowsDefaultOffAndAreNoOpWhenTheyCoverEverything() throws {
        let shot = ShotParameters(releaseAngle: Angle.radians(50), releaseSpeed: 7.2, releaseHeight: 2.4, releaseDistance: 4.19)
        let placement = CameraPlacement(viewAngle: Angle.radians(25), distance: 8, height: 1.2,
                                        intrinsics: CameraPlacement.iPhone1080p())
        var o = SimulationOptions(); o.fps = 120; o.seed = 3; o.rimNoisePx = 0
        let sim = ShotSimulator.simulate(shot, placement: placement, options: o)
        let rim = try RimCalibrator.calibrate(boundaryPoints: sim.rimBoundary, intrinsics: sim.camera.intrinsics,
                                              options: RimCalibrationOptions())
        let free = try XCTUnwrap(ShotPlaneSolver.solveByFixedGravity(sim.samples, calibration: rim, intrinsics: sim.camera.intrinsics))
        let everything = try XCTUnwrap(ShotPlaneSolver.solveByFixedGravity(sim.samples, calibration: rim, intrinsics: sim.camera.intrinsics,
                                                                           allowedAzimuths: [AzimuthWindow(center: 0, halfWidth: .pi)]))
        XCTAssertEqual(free.frame.azimuth, everything.frame.azimuth, accuracy: 1e-9)
        // An empty window set is a refusal, never a free scan.
        XCTAssertNil(ShotPlaneSolver.solveByFixedGravity(sim.samples, calibration: rim, intrinsics: sim.camera.intrinsics,
                                                         allowedAzimuths: []))
        // A window that excludes the true azimuth must not return it.
        let true0 = free.frame.azimuth
        let elsewhere = ShotPlaneSolver.solveByFixedGravity(sim.samples, calibration: rim, intrinsics: sim.camera.intrinsics,
                                                            allowedAzimuths: [AzimuthWindow(center: true0 + .pi / 2, halfWidth: Angle.radians(5))])
        if let e = elsewhere {
            XCTAssertGreaterThan(abs(atan2(sin(e.frame.azimuth - true0), cos(e.frame.azimuth - true0))), Angle.radians(60))
        }
    }

    func testAnalysisOptionsCourtAnchorDefaultsToNil() {
        XCTAssertNil(AnalysisOptions().courtAnchor)
    }

    /// The window set an anchor produces: a measured stance narrows it; nothing measured falls back
    /// to the court sector; and turning the fallback off makes it a refusal rather than a guess.
    func testAnchorWindows() throws {
        let c = court(cameraAt: SIMD3(4.0, -8.0, 1.2))
        let rim = try rimCalibration(c)
        let cal = try CourtCalibrator.solve(rim: rim, marks: CourtMarks(lines: [freeThrowLine(c), laneLine(c, side: 1, name: "laneLeft")],
                                                                        circles: [freeThrowCircle(c)]),
                                            intrinsics: c.intrinsics)
        let stance = try CourtCalibrator.floorPoint(try XCTUnwrap(c.pixel(SIMD3(4.6, -1.5, 0))), calibration: cal,
                                                    intrinsics: c.intrinsics, pixelSigma: 4, maximumRangeSigma: 3)
        let anchored = CourtShotAnchor(calibration: cal, standing: stance, azimuthTolerance: Angle.radians(12))
        let windows = anchored.azimuthWindows()
        XCTAssertEqual(windows.count, 1)
        XCTAssertLessThanOrEqual(windows[0].halfWidth, Angle.radians(30))
        XCTAssertTrue(windows[0].contains(try XCTUnwrap(stance.shotPlaneAzimuth)))

        let sectorOnly = CourtShotAnchor(calibration: cal)
        XCTAssertEqual(sectorOnly.azimuthWindows().count, 1)
        XCTAssertGreaterThan(sectorOnly.azimuthWindows()[0].halfWidth, Angle.radians(45))

        let refusing = CourtShotAnchor(calibration: cal, useCourtSectorFallback: false)
        XCTAssertTrue(refusing.azimuthWindows().isEmpty)
    }

    /// End to end: a court-anchored analysis of a synthetic shot must recover the release the
    /// simulator put in, and an anchor that allows nothing must refuse rather than fall back.
    func testCourtAnchoredAnalysisRecoversTheRelease() throws {
        let cameraCourt = SIMD3<Double>(3.5, -8.0, 1.2)
        let c = court(cameraAt: cameraCourt)
        let rim = try rimCalibration(c)
        let cal = try CourtCalibrator.solve(rim: rim, marks: CourtMarks(lines: [freeThrowLine(c), laneLine(c, side: 1, name: "laneLeft")],
                                                                        circles: [freeThrowCircle(c)]),
                                            intrinsics: c.intrinsics)
        // A shot from the free-throw line, simulated in the *court* frame these tests use.
        let feet = SIMD2<Double>(CourtMarkings.freeThrowLineDistance, 0)
        let releaseHeight = 2.35, speed = 7.25, angle = Angle.radians(51)
        let toRim = unit(SIMD3(-feet.x, -feet.y, 0))
        // Include the push phase before t = 0, so the release instant is *in* the footage and
        // `FlightWindowFinder` can find it — the same shape `ShotSimulator` produces.
        var samples: [ImageSample] = []
        let push = 0.18
        var t = -0.35
        while t < 1.2 {
            let s: Double
            if t >= 0 { s = speed * t }
            else if t <= -push { s = -speed * push / 2 }
            else { s = speed * (t + t * t / (2 * push)) }
            let p = SIMD3(feet.x + toRim.x * s * cos(angle), feet.y + toRim.y * s * cos(angle),
                          releaseHeight + s * sin(angle) - (t > 0 ? 0.5 * Court.g * t * t : 0))
            if let px = c.pixel(p), c.intrinsics.contains(px) { samples.append(ImageSample(t: t, uv: px)) }
            t += 1.0 / 120
        }
        XCTAssertGreaterThan(samples.count, 30)
        let stance = try CourtCalibrator.floorPoint(try XCTUnwrap(c.pixel(SIMD3(feet.x, feet.y, 0))), calibration: cal,
                                                    intrinsics: c.intrinsics, pixelSigma: 3, maximumRangeSigma: 2)
        var o = AnalysisOptions()
        o.courtAnchor = CourtShotAnchor(calibration: cal, standing: stance, azimuthTolerance: Angle.radians(10))
        let analysis = try ShotAnalyzer.analyze(track: samples, calibration: rim, intrinsics: c.intrinsics, options: o)
        XCTAssertEqual(analysis.fit.g, Court.g, accuracy: 0.6, "g is still the check, not an input")
        let release = try XCTUnwrap(analysis.metrics.release)
        XCTAssertEqual(release.height, releaseHeight, accuracy: 0.25)
        XCTAssertEqual(release.distance, CourtMarkings.freeThrowLineDistance, accuracy: 0.5)
        XCTAssertTrue(analysis.confidence.warnings.contains { $0.contains("court-anchored") })

        var refusing = o
        refusing.courtAnchor = CourtShotAnchor(calibration: cal, useCourtSectorFallback: false)
        XCTAssertThrowsError(try ShotAnalyzer.analyze(track: samples, calibration: rim, intrinsics: c.intrinsics, options: refusing))
    }
}
