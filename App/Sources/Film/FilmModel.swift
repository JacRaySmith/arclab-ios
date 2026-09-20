import AVFoundation
import Foundation
import Observation
import PhotosUI
import ShotGeometry
import ShotVideo
import SwiftUI

/// Drives one piece of game film: the player, the optional rim scan that pre-seeds shot *candidates*,
/// and the tags the shooter types.
///
/// **What it does not do.** It does not know who has the ball, whether anyone was open, or which team
/// a player is on. Nothing here tries. The only thing the app contributes on its own is a list of
/// moments where a ball arrived at a rim the shooter marked — and those are shown as candidates to
/// scrub to, never as facts about a possession.
///
/// The import, probe, slow-motion factor and rim calibration are `AnalysisModel`'s, unchanged: a game
/// clip is a clip, and that screen already knows how to read one.
@MainActor
@Observable
final class FilmModel {

    /// How much of a long clip the rim scan reads by default. Scanning is minutes of phone time for
    /// minutes of video, so it is bounded and the bound is on screen.
    static let defaultScanMinutes = 5.0

    let analysis = AnalysisModel()
    private(set) var film: FilmSession?
    var scanMinutes = FilmModel.defaultScanMinutes

    // Player
    private(set) var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    var currentSeconds: Double = 0
    var durationSeconds: Double = 0

    // Scanning
    private(set) var scanning = false
    private(set) var scanProgress: Double = 0
    private(set) var scanMessage: String?
    private(set) var scanError: String?
    private var scanTask: Task<Void, Never>?

    // Tagging state, kept sticky between tags so a whole game is one thumb.
    var who: FilmActor = .me
    var range: FilmRange = .unstated
    var pendingStartSeconds: Double?

    var hasClip: Bool { player != nil }
    var tags: [FilmTag] { film?.sortedTags ?? [] }
    var candidates: [ShotCandidate] { film?.candidates ?? [] }

    // MARK: - Bringing a clip in

    func importClip(_ item: PhotosPickerItem) {
        analysis.importAndProbe(item)
    }

    /// Called when `analysis.phase` becomes `.probed`: the clip is on disk and measured.
    func clipIsReady(title: String) {
        guard let clip = analysis.clip, let probe = analysis.probe else { return }
        let duration = max(probe.lastPTS, probe.trackDuration)
        var session = FilmSession(importedAt: Date(), title: title,
                                  durationSeconds: duration,
                                  frameRate: probe.measuredFrameRate,
                                  clipPath: clip.url.path)
        session.candidateNote = nil
        film = session
        durationSeconds = duration
        openPlayer(url: clip.url)
        ActivityLog.shared.event("film.imported", [
            "file": clip.url.lastPathComponent, "seconds": duration, "fps": probe.measuredFrameRate,
            "width": probe.width, "height": probe.height, "source": clip.source.rawValue,
        ])
    }

    /// Re-open a film that was saved earlier. The video may be gone (it lives in the temp directory
    /// iOS is free to empty); the tags never are, and the screen says which case it is.
    func reopen(_ saved: FilmSession) {
        film = saved
        durationSeconds = saved.durationSeconds
        if let url = saved.clipURL { openPlayer(url: url) } else { closePlayer() }
    }

    private func openPlayer(url: URL) {
        closePlayer()
        let p = AVPlayer(url: url)
        p.actionAtItemEnd = .pause
        player = p
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
                                                 queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.currentSeconds = t.seconds.isFinite ? t.seconds : 0 }
        }
    }

    func closePlayer() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player = nil
    }

    // MARK: - Scrubbing

    func seek(to seconds: Double) {
        currentSeconds = max(0, min(durationSeconds, seconds))
        player?.seek(to: CMTime(seconds: currentSeconds, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func nudge(_ delta: Double) { seek(to: currentSeconds + delta) }

    func togglePlay() {
        guard let player else { return }
        if player.rate == 0 { player.play() } else { player.pause() }
    }

    var isPlaying: Bool { (player?.rate ?? 0) > 0 }

    // MARK: - The assisted markers

    /// True when the rim scan can run at all: the rim has to be marked on a frame where it is visible.
    var canScan: Bool { analysis.calibration != nil && analysis.clip != nil && !scanning }

    var scanUnavailableReason: String? {
        if analysis.clip == nil { return "No clip is open." }
        if analysis.calibration == nil {
            return "The rim has not been marked. Mark it on a frame where the ring is clearly in view and the app can look for balls arriving at it. Without that, this timeline has no candidates — the app has nothing to measure a shot against."
        }
        return nil
    }

    func scanForCandidates() {
        guard let clip = analysis.clip, let cal = analysis.calibration, film != nil else { return }
        scanning = true; scanProgress = 0; scanError = nil; scanMessage = "Starting"
        var options = SessionScanOptions()
        options.scanEnd = scanMinutes * 60
        let url = clip.url, scale = analysis.timeScale, points = analysis.rimPoints
        let opts = options
        let log = ActivityLog.shared
        scanTask = Task { [cal] in
            do {
                let result = try await Task.detached(priority: .userInitiated) { [cal, opts] in
                    try await SessionScanner.run(url: url, timeScale: scale, calibration: cal, rimPoints: points,
                                                 options: opts) { fraction, message in
                        Task { @MainActor in
                            self.scanProgress = fraction
                            self.scanMessage = message
                        }
                    }
                }.value
                apply(result)
            } catch is CancellationError {
                scanMessage = nil
            } catch {
                scanError = "The scan stopped: \(error)"
            }
            scanning = false
            scanMessage = nil
            log.event("film.candidates", ["found": self.film?.candidates.count ?? 0,
                                          "scannedSeconds": self.scanMinutes * 60,
                                          "error": self.scanError])
        }
    }

    func cancelScan() { scanTask?.cancel() }

    private func apply(_ result: SessionScanResult) {
        guard var f = film else { return }
        f.candidates = result.windows.map {
            ShotCandidate(id: $0.id, fileSeconds: $0.arrivalFileTime,
                          arrivalDistancePx: $0.arrivalDistancePx, descentCandidates: $0.descentCandidates)
        }
        let scanned = result.scanned.upperBound - result.scanned.lowerBound
        f.candidateNote = String(format: "%d shot candidate%@ in the first %.0f minutes. These are places where a ball arrived at the rim you marked — a hint for where to scrub to, not a list of shots, and not a judgement about any of them. Anything at the other basket, or filmed while the camera moved, is missed; how much it misses on game film has NOT been measured.",
                                 f.candidates.count, f.candidates.count == 1 ? "" : "s", scanned / 60)
        film = f
    }

    // MARK: - Tagging

    func markPossessionStart() {
        pendingStartSeconds = currentSeconds
    }

    func tag(_ decision: FilmDecision) {
        guard var f = film else { return }
        let start = pendingStartSeconds ?? currentSeconds
        let tag = FilmTag(possessionStartSeconds: min(start, currentSeconds),
                          decisionSeconds: currentSeconds,
                          possessionEndSeconds: nil,
                          decision: decision, who: who, range: range, note: nil)
        f.tags.append(tag)
        film = f
        pendingStartSeconds = nil
        ActivityLog.shared.event("film.tag", ["decision": decision.name, "who": who.name,
                                              "range": range.name, "at": tag.decisionSeconds,
                                              "tags": f.tags.count])
    }

    func endPossessionHere() {
        guard var f = film, let last = f.tags.indices.last else { return }
        f.tags[last].possessionEndSeconds = currentSeconds
        film = f
    }

    func setNote(_ note: String, for id: UUID) {
        guard var f = film, let i = f.tags.firstIndex(where: { $0.id == id }) else { return }
        f.tags[i].note = note.isEmpty ? nil : note
        film = f
    }

    func removeTag(_ id: UUID) {
        guard var f = film else { return }
        f.tags.removeAll { $0.id == id }
        film = f
    }

    func rename(_ title: String) {
        guard var f = film else { return }
        f.title = title
        film = f
    }

    // MARK: - Saving

    func save(to store: FilmStore) {
        guard let f = film else { return }
        store.save(f)
    }
}
