import Foundation
import ShotGeometry
import ShotVideo
import simd

/// Unattended on-device benchmark, so the pipeline can be profiled on the real phone without
/// anyone tapping through the app. Driven entirely from the Mac over USB:
///
///   1. copy a clip to `Documents/ArcLab/bench/clip.mov` and a `bench.json` next to it
///      (`{"timeScale": 4, "hfovDegrees": 48, "rimPoints": [[u,v],…], "scanLimitSeconds": 300}`)
///   2. launch the app with the `-bench` argument
///   3. read `Documents/ArcLab/bench/result.json` and the activity log back.
///
/// It uses exactly the models the guided flow uses, so the numbers are the app's numbers.
@MainActor
enum BenchRunner {
    struct Spec: Codable {
        var timeScale: Double
        var hfovDegrees: Double
        var rimPoints: [[Double]]
        var scanLimitSeconds: Double?
        var maxShots: Int?
    }

    static var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ArcLab/bench", isDirectory: true)
    }

    static var requested: Bool {
        ProcessInfo.processInfo.arguments.contains("-bench") || ProcessInfo.processInfo.environment["ARCLAB_BENCH"] == "1"
    }

    static func runIfRequested(model: AnalysisModel, session: SessionModel) {
        guard requested else { return }
        Task { await run(model: model, session: session) }
    }

    static func run(model: AnalysisModel, session: SessionModel) async {
        let log = ActivityLog.shared
        let clipURL = directory.appendingPathComponent("clip.mov")
        let specURL = directory.appendingPathComponent("bench.json")
        guard FileManager.default.fileExists(atPath: clipURL.path), let data = try? Data(contentsOf: specURL),
              let spec = try? JSONDecoder().decode(Spec.self, from: data) else {
            log.event("bench.skipped", ["reason": "no clip.mov or bench.json in \(directory.path)"])
            return
        }
        log.event("bench.start", ["clip": clipURL.lastPathComponent, "timeScale": spec.timeScale, "hfov": spec.hfovDegrees,
                                  "scanLimit": spec.scanLimitSeconds, "thermal": ActivityLog.thermal()])
        let total = DispatchTime.now()

        // 1. clip + probe, the way useRecordedClip does it, but with the spec's timing.
        model.useLocalClip(url: clipURL, timeScale: spec.timeScale, hfovDegrees: spec.hfovDegrees)
        while model.phase == .probing { try? await Task.sleep(for: .milliseconds(100)) }
        guard model.phase == .probed else {
            log.event("bench.end", ["ok": false, "reason": "probe failed: \(model.phase)"])
            return
        }

        // 2. rim
        model.rimPoints = spec.rimPoints.compactMap { $0.count == 2 ? SIMD2($0[0], $0[1]) : nil }
        model.calibrateRim()
        guard model.calibration != nil else {
            log.event("bench.end", ["ok": false, "reason": "calibration failed: \(model.calibrationError ?? "?")"])
            return
        }

        // 3. scan
        session.reset()
        if let limit = spec.scanLimitSeconds { session.limitScan = true; session.scanLimitSeconds = limit }
        session.startScan(model: model)
        while session.scanning { try? await Task.sleep(for: .milliseconds(200)) }
        if let max = spec.maxShots, session.shots.count > max { session.shots = Array(session.shots.prefix(max)) }

        // 4. analyse
        session.analyseAll()
        while session.analysing { try? await Task.sleep(for: .milliseconds(200)) }

        let seconds = Double(DispatchTime.now().uptimeNanoseconds - total.uptimeNanoseconds) / 1e9
        let s = session.summary
        let result: [String: Any] = [
            "seconds": seconds, "windows": s.windows, "tracked": s.tracked, "accepted": s.accepted, "failed": s.failed,
            "releaseSpeed": s.releaseSpeed.map { ["mean": $0.mean, "sd": $0.sd ?? 0, "n": $0.n] } ?? "nil",
            "entryAngle": s.entryAngleDegrees.map { ["mean": $0.mean, "sd": $0.sd ?? 0, "n": $0.n] } ?? "nil",
            "shots": session.shots.map { shot -> [String: Any] in
                ["id": shot.id, "status": shot.statusLabel, "detail": shot.statusDetail ?? "",
                 "gFit": shot.row?.gFit ?? 0, "release": shot.row?.releaseSpeed ?? 0]
            },
            "thermal": ActivityLog.thermal(),
        ]
        if let out = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: directory.appendingPathComponent("result.json"), options: .atomic)
        }
        log.event("bench.end", ["ok": true, "seconds": seconds, "windows": s.windows, "tracked": s.tracked, "accepted": s.accepted,
                                "thermal": ActivityLog.thermal()])
    }
}
