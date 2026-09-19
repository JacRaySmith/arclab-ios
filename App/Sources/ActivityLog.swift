import Foundation
import AVFoundation
import OSLog
import UIKit

/// What the shooter did and what the app measured, as one JSON line per event, kept on the phone
/// under Documents/ArcLab/logs/activity-<day>.jsonl. Nothing leaves the device; the file is read
/// back over USB (`devicectl device copy from … --domain-type appDataContainer`) to review a test
/// session after the fact and to profile where the time goes on the real hardware.
///
/// Every event carries the wall-clock time and the seconds since launch; `timed` events carry a
/// duration. Values are plain strings/numbers so the log stays greppable.
final class ActivityLog: @unchecked Sendable {
    static let shared = ActivityLog()

    private let queue = DispatchQueue(label: "arclab.activitylog", qos: .utility)
    private let launch = Date()
    private let logger = Logger(subsystem: "com.arclab.app", category: "activity")
    private var handle: FileHandle?
    private var currentDay = ""

    static var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ArcLab/logs", isDirectory: true)
    }

    private init() {
        // Read the previous run's marker *before* stamping this one, so `app.launch` can say whether
        // the run before it ended on purpose. A run that ended cleanly wrote "endedCleanly": the
        // absence of that is the only evidence there is when iOS kills a process without a report.
        let previous = RunMarker.read()
        // Stamped before the first event, so nothing on `queue` can race this assignment.
        marker = RunMarker(startedAt: launch)
        marker.write()
        event("app.launch", [
            "device": UIDevice.current.model, "system": UIDevice.current.systemVersion,
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            "processors": ProcessInfo.processInfo.activeProcessorCount,
            "memoryGB": Double(ProcessInfo.processInfo.physicalMemory) / 1e9,
            "thermal": ActivityLog.thermal(),
            "previousRunEndedCleanly": previous?.endedCleanly,
            "previousRunLastScreen": previous?.lastScreen,
            "previousRunLastEvent": previous?.lastEvent,
            "previousRunSeconds": previous.map { ($0.lastSeenAt.timeIntervalSince($0.startedAt) * 1000).rounded() / 1000 },
            "previousRunEndedAt": previous?.lastSeenAt.formatted(.iso8601),
        ])
        observeAppLifecycle()
    }

    // MARK: The clean-exit marker

    /// One tiny file rewritten as the app moves through its life, so the *next* launch can say how the
    /// last one ended. `endedCleanly` is set only by `didEnterBackground` / `willTerminate`; anything
    /// else — a crash, a jetsam, a watchdog kill, a force-quit from the app switcher — leaves it false.
    /// It is not a crash report and never pretends to be one: it says "this run did not say goodbye",
    /// plus the last screen the shooter was on and the last event written.
    struct RunMarker: Codable, Sendable {
        var startedAt: Date
        var lastSeenAt: Date = Date()
        var endedCleanly = false
        var lastScreen = "?"
        var lastEvent = "?"

        static var fileURL: URL {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let dir = base.appendingPathComponent("ArcLab", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("run-marker.json")
        }

        static func read() -> RunMarker? {
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(RunMarker.self, from: data)
        }

        func write() {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(self) else { return }
            try? data.write(to: RunMarker.fileURL, options: .atomic)
        }
    }

    /// Only ever touched on `queue`, alongside the log writes, so the marker on disk and the last line
    /// of the log always agree about which event was the last one.
    private var marker = RunMarker(startedAt: Date())
    private var markerWrittenAt = Date.distantPast

    private func observeAppLifecycle() {
        let center = NotificationCenter.default
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification] {
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.setEndedCleanly(true, why: name == UIApplication.willTerminateNotification ? "terminate" : "background")
            }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            self?.setEndedCleanly(false, why: "active")
        }
    }

    private func setEndedCleanly(_ clean: Bool, why: String) {
        event("app.\(why)")
        queue.async { [self] in
            marker.endedCleanly = clean
            marker.lastSeenAt = Date()
            marker.write()
            markerWrittenAt = Date()
        }
    }

    /// Every video format of the back wide camera with its field of view, once per launch — the field of
    /// view of the slo-mo format is the lens constant the geometry needs and it was never measured before.
    static func logCameraFormats() {
        guard let found = cameraFormats() else {
            shared.event("camera.formats", ["available": false]); return
        }
        shared.event("camera.formats", ["device": found.device,
                                        "formats": found.formats.map(\.logLine).joined(separator: "; ")])
    }

    /// One high-frame-rate video format of the back wide camera. The field of view is the lens
    /// constant the geometry needs, read from the format rather than assumed.
    struct CameraFormat: Identifiable, Sendable {
        var width: Int
        var height: Int
        var maxFrameRate: Double
        var fieldOfViewDegrees: Float
        var binned: Bool

        var id: String { "\(width)x\(height)@\(Int(maxFrameRate.rounded()))\(binned ? "b" : "")" }
        var logLine: String {
            String(format: "%dx%d@%.0f fov %.2f binned %d", width, height, maxFrameRate, fieldOfViewDegrees, binned ? 1 : 0)
        }
        var resolution: String { "\(width) × \(height)" }
        var detail: String {
            String(format: "%.0f fps · %.1f° horizontal field of view%@", maxFrameRate, fieldOfViewDegrees,
                   binned ? " · binned" : "")
        }
    }

    /// The same enumeration `logCameraFormats` writes to the log, returned so a screen can show it
    /// read-only. Nil when there is no back wide camera (the simulator).
    static func cameraFormats() -> (device: String, formats: [CameraFormat])? {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            return nil
        }
        var rows: [CameraFormat] = []
        for f in device.formats {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard d.width >= 1280 else { continue }
            let maxFps = f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            guard maxFps >= 60 else { continue }
            rows.append(CameraFormat(width: Int(d.width), height: Int(d.height), maxFrameRate: maxFps,
                                     fieldOfViewDegrees: f.videoFieldOfView, binned: f.isVideoBinned))
        }
        return (device.localizedName, rows)
    }

    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// Record one event. `fields` may hold String, Int, Double, Bool or nil; anything else is described.
    func event(_ name: String, _ fields: [String: Any?] = [:]) {
        let now = Date()
        let uptime = now.timeIntervalSince(launch)
        var record: [String: Any] = ["t": ISO8601DateFormatter.log.string(from: now), "up": (uptime * 1000).rounded() / 1000, "event": name]
        for (k, v) in fields {
            guard let v else { record[k] = NSNull(); continue }
            switch v {
            case let s as String: record[k] = s
            case let i as Int: record[k] = i
            case let d as Double: record[k] = d.isFinite ? (d * 1000).rounded() / 1000 : "nan"
            case let b as Bool: record[k] = b
            case let f as Float: record[k] = Double(f)
            default: record[k] = String(describing: v)
            }
        }
        queue.async { [self] in write(record) }
        logger.info("\(name, privacy: .public) \(fields.map { "\($0.key)=\($0.value.map { String(describing: $0) } ?? "nil")" }.joined(separator: " "), privacy: .public)")
    }

    /// Time a piece of work and log it with its duration in seconds, whether it succeeds or throws.
    @MainActor func timed<T>(_ name: String, _ fields: [String: Any?] = [:], _ work: @MainActor () async throws -> T) async rethrows -> T {
        let start = DispatchTime.now()
        var extra = fields
        do {
            let result = try await work()
            extra["seconds"] = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
            extra["ok"] = true
            event(name, extra)
            return result
        } catch {
            extra["seconds"] = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
            extra["ok"] = false
            extra["error"] = "\(error)"
            event(name, extra)
            throw error
        }
    }

    /// A stopwatch for stage timings inside one piece of work: `lap("decode")` logs the seconds since
    /// the previous lap under `name.stage`.
    final class Stopwatch: @unchecked Sendable {
        let name: String
        let fields: [String: Any?]
        private var last = DispatchTime.now()
        private let start = DispatchTime.now()
        init(_ name: String, _ fields: [String: Any?] = [:]) { self.name = name; self.fields = fields }
        func lap(_ stage: String, _ extra: [String: Any?] = [:]) {
            let now = DispatchTime.now()
            var f = fields
            for (k, v) in extra { f[k] = v }
            f["stage"] = stage
            f["seconds"] = Double(now.uptimeNanoseconds - last.uptimeNanoseconds) / 1e9
            f["sinceStart"] = Double(now.uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
            last = now
            ActivityLog.shared.event(name + ".stage", f)
        }
    }

    /// Liveness while long work runs: at most one "heartbeat" event per 15 s, carrying the latest
    /// progress and the thermal state, so a stalled run and a slow run look different in the log.
    final class Heartbeat: @unchecked Sendable {
        private let lock = NSLock()
        private var last = DispatchTime.now().uptimeNanoseconds - 20_000_000_000
        func tick(_ what: String, _ fields: [String: Any?] = [:]) {
            let now = DispatchTime.now().uptimeNanoseconds
            lock.lock(); let due = now - last >= 15_000_000_000; if due { last = now }; lock.unlock()
            guard due else { return }
            var f = fields; f["what"] = what; f["thermal"] = ActivityLog.thermal()
            ActivityLog.shared.event("heartbeat", f)
        }
    }

    // MARK: Reading back

    /// Every log file, newest first.
    static func files() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func tail(lines: Int = 200) -> String {
        guard let url = files().first, let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }

    // MARK: Private

    private func write(_ record: [String: Any]) {
        let day = String(ISO8601DateFormatter.log.string(from: Date()).prefix(10))
        if handle == nil || day != currentDay {
            handle?.closeFile()
            try? FileManager.default.createDirectory(at: ActivityLog.directory, withIntermediateDirectories: true)
            let url = ActivityLog.directory.appendingPathComponent("activity-\(day).jsonl")
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            handle = try? FileHandle(forWritingTo: url)
            handle?.seekToEndOfFile()
            currentDay = day
        }
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        handle?.write(data)
        handle?.write(Data([0x0A]))
        updateMarker(with: record)
    }

    /// Keep the run marker roughly level with the log. A `screen` event rewrites it at once — that is
    /// the field the next launch reads to say where the app was when it died — and everything else at
    /// most once every two seconds, so an analysis writing hundreds of events does not write hundreds
    /// of files.
    private func updateMarker(with record: [String: Any]) {
        let name = record["event"] as? String ?? "?"
        let isScreen = name == "screen"
        if isScreen, let screen = record["name"] as? String { marker.lastScreen = screen }
        marker.lastEvent = name
        marker.lastSeenAt = Date()
        guard isScreen || Date().timeIntervalSince(markerWrittenAt) > 2 else { return }
        marker.write()
        markerWrittenAt = Date()
    }
}

extension ISO8601DateFormatter {
    /// ISO 8601 with fractional seconds, via the thread-safe `Date.ISO8601FormatStyle`.
    enum log {
        static func string(from date: Date) -> String {
            date.formatted(.iso8601.year().month().day().timeZone(separator: .omitted).time(includingFractionalSeconds: true))
        }
    }
}
