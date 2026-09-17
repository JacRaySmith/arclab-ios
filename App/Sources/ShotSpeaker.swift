import AVFoundation
import Foundation
import SwiftUI

/// Speaks each shot's result as it is measured so the shooter never has to look at the phone
/// (design note § 4 "Speak it"). On-device `AVSpeechSynthesizer`, no network.
///
/// What is said, and nothing else:
///   accepted shot  → release speed to one decimal ("7.2"), then depth vs the make band in whole
///                    centimetres ("4 long" / "6 short" / "in the band");
///   anything else  → "not measured".
/// Never a joint angle, never a target. A number that is nil is said to be not measured, not invented.
///
/// Rate limit: at most one utterance is pending behind the one being spoken; a newer shot replaces
/// the pending one, so a burst of results (a re-analysis, say) ends on the newest shot.
@MainActor
final class ShotSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    /// Which screen is speaking; each keeps its own persisted toggle (`ShooterProfile`-style UserDefaults).
    enum Mode: String {
        case practice, guided
        var key: String { "speaker.enabled.\(rawValue)" }
        /// Default ON while practising (the phone is on a tripod), OFF in the guided flow (the shooter is at the phone).
        var defaultEnabled: Bool { self == .practice }
        var isEnabled: Bool {
            UserDefaults.standard.object(forKey: key) == nil ? defaultEnabled : UserDefaults.standard.bool(forKey: key)
        }
    }

    static let shared = ShotSpeaker()

    private let synthesizer = AVSpeechSynthesizer()
    private var pending: String?
    private var lastSpokenKey: String?

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: Text

    /// Same band edges as the on-screen feedback lines (0.25–0.28 m past the front rim), so what is
    /// heard matches what is read. Rounded to whole centimetres.
    static func text(for row: BlockRow) -> String {
        guard row.verdict.isAccepted else { return "not measured" }
        let speed = row.releaseSpeed.map { String(format: "%.1f", $0) } ?? "speed not measured"
        let depth: String
        if let d = row.depthPastFrontRim {
            if d > 0.28 { depth = String(format: "%.0f long", (d - 0.28) * 100) }
            else if d < 0.25 { depth = String(format: "%.0f short", (0.25 - d) * 100) }
            else { depth = "in the band" }
        } else {
            depth = "depth not measured"
        }
        return "\(speed). \(depth)."
    }

    // MARK: Speaking

    /// Call whenever `SessionModel.lastMeasured` changes. Speaks the shot once (keyed on its id and
    /// completion order) unless `mode` is muted.
    func announce(_ shot: SessionShot?, mode: Mode) {
        guard let shot, let row = shot.row else { return }
        let key = "\(shot.id)#\(shot.completionOrder ?? -1)"
        guard key != lastSpokenKey else { return }
        lastSpokenKey = key
        guard mode.isEnabled else { return }
        speak(Self.text(for: row), shot: shot.id, mode: mode)
    }

    /// Stop what is being said (used when the shooter mutes mid-block).
    func silence() {
        pending = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    private func speak(_ text: String, shot: Int, mode: Mode) {
        ActivityLog.shared.event("speak", ["text": text, "shot": shot, "mode": mode.rawValue, "queued": synthesizer.isSpeaking])
        if synthesizer.isSpeaking {
            pending = text   // replaces any older pending line: never more than one waiting
            return
        }
        start(text)
    }

    private func start(_ text: String) {
        activateAudioSession()
        let utterance = AVSpeechUtterance(string: text)
        utterance.prefersAssistiveTechnologySettings = false
        utterance.postUtteranceDelay = 0.2
        synthesizer.speak(utterance)
    }

    private func drain() {
        if let next = pending {
            pending = nil
            start(next)
        } else {
            deactivateAudioSession()
        }
    }

    // MARK: Audio session

    /// Playback that ducks whatever else is playing (music on the court speaker) and, being a playback
    /// category, is the one that can keep speaking with the screen locked. The capture session
    /// reconfigures the audio session itself when recording starts, so nothing is restored here.
    private func activateAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            ActivityLog.shared.event("speak.audioSession", ["error": String(describing: error)])
        }
    }

    private func deactivateAudioSession() {
        // Releases the ducking so the other audio comes back up between shots.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: AVSpeechSynthesizerDelegate (called off the main actor)

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.drain() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.drain() }
    }
}

// MARK: - The toggle

/// The speaker icon for a navigation bar. Persists through `mode.key`; muting stops any speech in progress.
struct ShotSpeakerToggle: View {
    let mode: ShotSpeaker.Mode
    @AppStorage private var enabled: Bool

    init(mode: ShotSpeaker.Mode) {
        self.mode = mode
        _enabled = AppStorage(wrappedValue: mode.defaultEnabled, mode.key)
    }

    var body: some View {
        Button {
            enabled.toggle()
            if !enabled { ShotSpeaker.shared.silence() }
            ActivityLog.shared.event("speak.toggle", ["mode": mode.rawValue, "enabled": enabled])
        } label: {
            Image(systemName: enabled ? "speaker.wave.2.fill" : "speaker.slash")
        }
        .accessibilityLabel(enabled ? "Spoken results on" : "Spoken results off")
    }
}
