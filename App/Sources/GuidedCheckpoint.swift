import Foundation
import ShotGeometry
import simd

// ================================================================================================
// MARK: - What the app was in the middle of
// ================================================================================================

/// The guided (and practice-block) flow, written to disk at every step that changes what is known, so
/// that a process death cannot take a session with it.
///
/// On 2026-09-18 the screen went black mid-session and the app relaunched twice; `SessionModel`'s own
/// header said it plainly — *"nothing persisted anywhere. Everything here lives for as long as the app
/// is open"* — so a 45-minute block of filming and ten minutes of analysis went with it. The `.mov`
/// itself was never in danger (it is written to `Documents/ArcLab/Recordings` and nothing deletes it),
/// but everything the app had *learned* from it was in memory only.
///
/// Honesty (CLAUDE.md rule 1) decides the shape of this file:
/// * A shot is either **measured** — and then its whole `SavedShot` record is here, numbers, verdict,
///   reasons and form included, so nothing has to be recomputed or guessed — or it is **failed** with
///   the reason it failed, or it is neither and comes back **queued**. There is no fourth state and no
///   zero anywhere: a window that was never analysed is restored as not measured.
/// * The rim points and the lens are kept, not just the calibration, so a resumed session measures its
///   remaining shots with *the same ruler* the first ones were measured with. A re-found ring would be
///   a second ruler, and mixing two is exactly the kind of quiet error the brief forbids.
struct GuidedCheckpoint: Codable, Sendable, Identifiable {
    /// The furthest step this session reached. Nothing is inferred from the arrays: this is written.
    enum Step: String, Codable, Sendable {
        /// A clip is on disk and belongs to this session. Nothing measured yet.
        case recorded
        /// The whole-clip scan finished and the windows are known.
        case scanned
        /// At least one window has been analysed.
        case analysing
        /// Every window has a result or a reason, and the session is ready to save (or is saved).
        case analysed
    }

    /// One rim boundary point, in image pixels. `SIMD2<Double>` is not `Codable`, and the exact points
    /// are what make the restored calibration identical rather than merely similar.
    struct Point: Codable, Sendable {
        var x: Double
        var y: Double
        init(_ v: SIMD2<Double>) { x = v.x; y = v.y }
        var simd: SIMD2<Double> { SIMD2(x, y) }
    }

    /// A window that was analysed and produced no numbers, with the reason it produced none.
    struct FailedShot: Codable, Sendable {
        var id: Int
        var reason: String
    }

    var id = UUID()
    var startedAt = Date()
    var updatedAt = Date()
    var step: Step = .recorded

    /// Which screen owns this session, so "resume" reopens the right one.
    var flow: String = "guided"

    var spot: ShotSpot?
    /// The `.mov`'s file name inside `RecordedClip.recordingsDirectory`. Never an absolute path: the
    /// container path changes between installs.
    var clipFileName: String?
    /// What the finished file was measured to be, copied in so the resume screen can describe the clip
    /// even if its sidecar has gone. `nil` means it was never measured, and the UI says so.
    var measuredFrameRate: Double?
    var durationSeconds: Double?

    var hfovDegrees: Double = 48
    var timeScale: Double = 1
    var rimPoints: [Point] = []
    var rimFrameTime: Double?

    /// Set when the clip belongs to a practice block, so resuming goes back to the block screen and the
    /// block is still scored against the plan.
    var practiceSessionID: UUID?
    var practiceBlockID: UUID?

    var windows: [ShotWindow] = []
    var measured: [SavedShot] = []
    var failed: [FailedShot] = []
    /// Set once the session has been written to `SessionStore`. A checkpoint with this set is finished
    /// and is deleted; it exists only so a death *between* the save and the delete is not a duplicate.
    var savedSessionID: UUID?

    // MARK: What it says

    var clip: RecordedClip? {
        guard let clipFileName else { return nil }
        return try? RecordedClip.load(url: RecordedClip.recordingsDirectory.appendingPathComponent(clipFileName))
    }

    var clipURL: URL? {
        clipFileName.map { RecordedClip.recordingsDirectory.appendingPathComponent($0) }
    }

    var clipExists: Bool {
        guard let clipURL else { return false }
        return FileManager.default.fileExists(atPath: clipURL.path)
    }

    var measuredCount: Int { measured.count }
    var failedCount: Int { failed.count }

    /// Windows that were never analysed at all. Counted from the windows, not assumed.
    var unmeasuredCount: Int {
        let done = Set(measured.map(\.id)).union(failed.map(\.id))
        return windows.filter { !done.contains($0.id) }.count
    }

    /// Worth offering to the shooter? A checkpoint with no clip on disk and nothing measured is
    /// nothing to come back to.
    var isWorthResuming: Bool {
        guard savedSessionID == nil else { return false }
        if measuredCount > 0 { return true }
        return clipExists
    }

    /// The one line the Today screen shows. Every number in it is counted, never estimated.
    var summaryLine: String {
        var parts: [String] = []
        if let spot { parts.append(spot.rawValue) }
        if !windows.isEmpty {
            parts.append("\(measuredCount) of \(windows.count) shot\(windows.count == 1 ? "" : "s") measured")
        } else if step == .recorded {
            parts.append("recorded, not yet scanned")
        }
        if failedCount > 0 { parts.append("\(failedCount) could not be measured") }
        if !clipExists { parts.append("the recording is no longer on this phone") }
        return parts.joined(separator: " · ")
    }

    /// Why a step of this checkpoint cannot be picked up, or `nil` when all of it can. Shown in the UI
    /// rather than quietly dropping anything.
    var resumeObstacle: String? {
        if !clipExists, unmeasuredCount > 0 {
            return "The recording \(clipFileName ?? "for this session") is no longer on this phone, so the \(unmeasuredCount) shot\(unmeasuredCount == 1 ? "" : "s") that \(unmeasuredCount == 1 ? "was" : "were") never measured cannot be measured now. The \(measuredCount) already measured can still be saved."
        }
        if !clipExists {
            return "The recording is no longer on this phone. Every shot had already been measured, so nothing is lost — the session can still be saved."
        }
        if rimPoints.count < 5 {
            return "The ring was never marked in this session, so it has to be found again before the remaining shots can be measured. The shots already measured keep the numbers they were measured with."
        }
        return nil
    }
}

// ================================================================================================
// MARK: - Where it lives
// ================================================================================================

/// One file, rewritten in place. There is only ever one session in progress, so there is only ever one
/// checkpoint; finishing or discarding it deletes the file.
@MainActor
enum GuidedCheckpointStore {
    static let fileName = "guided-checkpoint.json"

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ArcLab", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }

    /// Why the last read or write failed, so a screen can say so instead of behaving as if there had
    /// never been a session.
    private(set) static var lastError: String?

    static func load() -> GuidedCheckpoint? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let checkpoint = try decoder.decode(GuidedCheckpoint.self, from: Data(contentsOf: fileURL))
            lastError = nil
            return checkpoint
        } catch {
            lastError = "the session checkpoint could not be read: \(error)"
            ActivityLog.shared.event("checkpoint.read.failed", ["error": "\(error)"])
            return nil
        }
    }

    /// One serial queue for every write and every delete, so they land on disk in the order they were
    /// asked for. Without that, "save the session, then delete its checkpoint" could complete in the
    /// other order and leave a checkpoint that would offer to resume a session already in the store.
    private static let writeQueue = DispatchQueue(label: "com.arclab.checkpoint", qos: .utility)

    /// Written off the main thread: a checkpoint carrying thirty shots' worth of form is a few hundred
    /// kilobytes, and it is written after every shot while the analysis is still running.
    static func write(_ checkpoint: GuidedCheckpoint) {
        var copy = checkpoint
        copy.updatedAt = Date()
        let url = fileURL
        writeQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            do {
                try encoder.encode(copy).write(to: url, options: .atomic)
            } catch {
                ActivityLog.shared.event("checkpoint.write.failed", ["error": "\(error)"])
            }
        }
    }

    static func clear(why: String) {
        ActivityLog.shared.event("checkpoint.cleared", ["why": why])
        let url = fileURL
        writeQueue.async { try? FileManager.default.removeItem(at: url) }
    }
}

// ================================================================================================
// MARK: - Putting one back
// ================================================================================================

/// The two halves of a resume, shared by the guided screen and the practice-block screen so that a
/// session recovered from either is recovered in exactly the same way.
@MainActor
enum GuidedResume {
    /// Step one: put the clip back in front of the models. Returns the sentence to show the shooter
    /// when the clip cannot be loaded at all, or `nil` when the reload has started.
    ///
    /// The probe is *re-run* rather than restored: the frame rate and the frame size are measurements
    /// of the file, and reading them again from the file costs a second and cannot be stale.
    static func begin(_ checkpoint: GuidedCheckpoint, model: AnalysisModel) -> String? {
        guard checkpoint.clipExists, let url = checkpoint.clipURL else {
            return checkpoint.resumeObstacle
                ?? "The recording for this session is no longer on this phone, so it cannot be reopened."
        }
        if let recorded = checkpoint.clip {
            model.useRecordedClip(recorded)
        } else {
            // The `.mov` is there but its sidecar is not. The timing still comes from the file; only
            // the lens angle, which is not in the file, comes from the checkpoint.
            ActivityLog.shared.event("checkpoint.sidecarMissing", ["clip": checkpoint.clipFileName])
            model.useLocalClip(url: url, timeScale: checkpoint.timeScale, hfovDegrees: checkpoint.hfovDegrees)
        }
        return nil
    }

    /// What `finish` managed to do.
    enum Finish {
        /// The clip is not readable yet — call again when the model has probed it.
        case notReady
        /// Restored. `queued` windows still need measuring; `measured` came back with their numbers.
        case restored(measured: Int, queued: Int)
        /// There was nothing measured to restore: the clip is back and the ordinary flow takes over
        /// (find the ring, scan, analyse).
        case clipOnly
        /// Could not be restored, and this is the reason — shown, never swallowed.
        case blocked(String)
    }

    /// Step two: rebuild the ring this session was measured with, then hand the checkpoint to
    /// `SessionModel.restore`. Call it whenever the model's phase changes; it is a no-op until the
    /// clip has been probed.
    static func finish(_ checkpoint: GuidedCheckpoint, model: AnalysisModel, session: SessionModel) -> Finish {
        guard model.clip != nil, model.probe != nil else { return .notReady }
        guard !checkpoint.measured.isEmpty || !checkpoint.windows.isEmpty else { return .clipOnly }
        guard checkpoint.rimPoints.count >= 5 else {
            // No ring was ever marked, so there is nothing measured either: let the ordinary flow run.
            return checkpoint.measuredCount == 0 ? .clipOnly
                : .blocked(checkpoint.resumeObstacle ?? "The ring this session used was not kept.")
        }
        // The same points and the same lens give the same calibration: the restored shots and the ones
        // measured from here on share one ruler. A ring found afresh would be a second one.
        model.hfovDegrees = checkpoint.hfovDegrees
        model.rimPoints = checkpoint.rimPoints.map(\.simd)
        model.rimFrameTime = checkpoint.rimFrameTime
        model.calibrateRim()
        guard model.calibration != nil else {
            return .blocked("The ring this session was measured with could not be rebuilt (\(model.calibrationError ?? "no reason was given")), so the \(checkpoint.unmeasuredCount) shot(s) that were never measured cannot be measured with the same ruler. The \(checkpoint.measuredCount) already measured are unchanged and can still be saved.")
        }
        guard session.restore(from: checkpoint, model: model) else {
            return .blocked("The session was busy, so the checkpoint was not applied. Leave this screen and come back.")
        }
        let queued = session.shots.filter { if case .queued = $0.status { return true }; return false }.count
        return .restored(measured: session.shots.filter { $0.row != nil }.count, queued: queued)
    }
}

// ================================================================================================
// MARK: - Building one from the live models
// ================================================================================================

extension GuidedCheckpoint {
    /// Bring the checkpoint up to date with whatever the models now hold. Called after the recording,
    /// after the scan, and after every shot finishes — the three moments at which something would
    /// otherwise be lost.
    @MainActor
    mutating func update(model: AnalysisModel, session: SessionModel) {
        hfovDegrees = model.hfovDegrees
        timeScale = model.timeScale
        if !model.rimPoints.isEmpty { rimPoints = model.rimPoints.map(Point.init) }
        rimFrameTime = model.rimFrameTime
        if !session.shots.isEmpty { windows = session.shots.map(\.window) }
        measured = session.shots.compactMap { shot in
            shot.row.map { SavedShot(shot: shot, row: $0) }
        }
        failed = session.shots.compactMap { shot in
            if case .failed(let reason) = shot.status { return FailedShot(id: shot.id, reason: reason) }
            return nil
        }
        savedSessionID = session.savedSessionID
        if !windows.isEmpty {
            step = unmeasuredCount == 0 ? .analysed : (measuredCount + failedCount > 0 ? .analysing : .scanned)
        }
    }
}
