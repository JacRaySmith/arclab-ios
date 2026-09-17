import Foundation
import ShotGeometry
import UIKit

/// Files one `BodyShot` per accepted shot under `Documents/ArcLab/body/<session>/<shotID>.json`
/// (docs/BIOMETRIC-SCHEMA.md §6) — the full-frame record the future 3-D skeletal / mesh model reads.
///
/// Writes are atomic and off the main actor; the newest `keepLast` files are kept and older ones are
/// removed after each write. Nothing leaves the device.
enum BodyShotWriter {
    static let keepLast = 500
    private static let queue = DispatchQueue(label: "arclab.bodyshot", qos: .utility)

    static var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ArcLab/body", isDirectory: true)
    }

    /// The session's directory name: the saved session's UUID when it has one, else the clip's name.
    static func url(sessionKey: String, shotID: Int) -> URL {
        let safe = sessionKey.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "_" }
        return directory.appendingPathComponent(String(safe), isDirectory: true).appendingPathComponent("\(shotID).json")
    }

    /// Encode and write on the background queue. The record's `source` gets the device, the build and
    /// the lens provenance here — the runner does not know them; the frame size, fps and field of view
    /// it already filled in are kept.
    static func write(_ shot: BodyShot, sessionKey: String, shotID: Int, hfovProvenance: String) {
        var record = shot
        record.source.kind = "app"
        record.source.device = UIDevice.current.model + " / iOS " + UIDevice.current.systemVersion
        record.source.build = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
            + " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?") + ")"
        record.source.format.provenance = hfovProvenance
        let target = url(sessionKey: sessionKey, shotID: shotID)
        queue.async {
            let t0 = DispatchTime.now().uptimeNanoseconds
            do {
                let data = try record.encoded()
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
                // The encode is a whole timeline through `JSONEncoder`; it is the one part of the export that
                // is worth counting, and it never showed up in any per-window total because it happens here.
                ActivityLog.shared.event("body.export", ["path": target.path, "bytes": data.count,
                                                         "frames": record.frames.count, "shot": shotID,
                                                         "seconds": Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9])
                delete(olderThan: keepLast)
            } catch {
                ActivityLog.shared.event("body.export.failed", ["path": target.path, "error": "\(error)"])
            }
        }
    }

    /// Read one record back. Returns nil when the file is missing, unreadable, or written to a
    /// schema version this build does not know — the decoder refuses those rather than guessing.
    static func load(url: URL) -> BodyShot? {
        do {
            return try BodyShot.decode(Data(contentsOf: url))
        } catch {
            ActivityLog.shared.event("body.read.failed", ["path": url.path, "error": "\(error)"])
            return nil
        }
    }

    /// Every record on disk, newest first.
    static func list() -> [URL] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        var files: [(URL, Date)] = []
        for case let u as URL in e where u.pathExtension == "json" {
            let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            files.append((u, d))
        }
        return files.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// Keep the newest `keep` records, remove the rest (and any session directory left empty).
    @discardableResult
    static func delete(olderThan keep: Int) -> Int {
        let files = list()
        guard files.count > keep else { return 0 }
        var removed = 0
        for u in files[keep...] {
            if (try? FileManager.default.removeItem(at: u)) != nil { removed += 1 }
            let dir = u.deletingLastPathComponent()
            if let rest = try? FileManager.default.contentsOfDirectory(atPath: dir.path), rest.isEmpty {
                try? FileManager.default.removeItem(at: dir)
            }
        }
        if removed > 0 { ActivityLog.shared.event("body.export.prune", ["removed": removed, "kept": keep]) }
        return removed
    }

    /// Total bytes on disk, for the settings screen or a log line.
    static func totalBytes() -> Int {
        list().reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }
}
