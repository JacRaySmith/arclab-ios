import Foundation

/// The shooter's standing height — the one input the body model's metres need, and the only one the
/// app asks a person for.
///
/// Iteration 2 of the body model (`docs/PHASE2-PREP.md`, "Body model, iteration 2") settled where a
/// metre scale may come from: the shooter's stated standing height against their ankle-to-nose pixel
/// span is accepted; the rim ruler is **refused**, because on an oblique view the shooter is not at
/// the rim's depth and the ruler implied standing heights of 2.30 / 2.29 / 1.24 m on the three
/// labelled windows. So nothing here ever derives a height from the rim: without a stated height
/// every metre in the body model is nil with `missingReason`.
enum ShooterProfile {
    static let key = "shooter.heightCm"

    /// The reason every metre carries when no height has been given. One sentence, the same everywhere.
    static let missingReason = "shooter height not given"

    /// Heights a person can plausibly state. Outside it the value is ignored rather than clamped.
    static let plausibleCm = 120.0...230.0

    /// Centimetres, or nil when nothing plausible has been stored. Thread-safe: `UserDefaults` is.
    static var heightCm: Double? {
        get {
            let cm = UserDefaults.standard.double(forKey: key)
            return plausibleCm.contains(cm) ? cm : nil
        }
        set {
            if let newValue, plausibleCm.contains(newValue) { UserDefaults.standard.set(newValue, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    static var heightMetres: Double? { heightCm.map { $0 / 100 } }

    /// The sentence the video step and the session screen show under the field.
    static let prompt = "Your height, for the metres in the body model — optional"

    static let explanation = """
        A single camera cannot recover metres on its own. With your standing height the body model can \
        put jump height and dip depth in metres, measured against your own ankle-to-nose pixel span; \
        without it those numbers stay unavailable and everything else — the angles, the timings, the \
        head steadiness — is unaffected. The rim's ring is not used as a body ruler: on an angled view \
        you are not at the rim's depth, and it was measured to be wrong by about a quarter.
        """
}

import SwiftUI

/// The one-line setting. Optional everywhere it appears: leaving it blank costs the metres and
/// nothing else, and the row says so rather than nagging.
struct ShooterHeightRow: View {
    /// True in the video step, where there is room for the reason; false in the denser session screen.
    var detailed = false

    @AppStorage(ShooterProfile.key) private var heightCm: Double = 0
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Your height") {
                HStack(spacing: 6) {
                    TextField("optional", text: $text)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                    Text("cm").foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            Text(ShooterProfile.prompt).font(.caption).foregroundStyle(.secondary)
            if !text.isEmpty, Double(text.trimmingCharacters(in: .whitespaces)).map(ShooterProfile.plausibleCm.contains) != true {
                Text(String(format: "Not used: a standing height between %.0f and %.0f cm is what the body model can work with.",
                            ShooterProfile.plausibleCm.lowerBound, ShooterProfile.plausibleCm.upperBound))
                    .font(.caption2).foregroundStyle(.orange)
            }
            if detailed {
                Text(ShooterProfile.explanation).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { text = heightCm > 0 ? String(format: "%.0f", heightCm) : "" }
        .onChange(of: text) { _, new in
            let v = Double(new.trimmingCharacters(in: .whitespaces))
            heightCm = (v.map(ShooterProfile.plausibleCm.contains) == true) ? (v ?? 0) : 0
        }
    }
}

// MARK: - Shooting hand

/// The one other thing a person can state about themselves. Nothing in the geometry needs it — the
/// pipeline finds the shooting wrist from the ball, not from a setting — so it is recorded for the
/// wording of cues and for the left/right convention on the rim map, and "not said" is a real answer.
extension ShooterProfile {
    enum ShootingHand: String, CaseIterable, Identifiable, Sendable {
        case unstated, right, left

        var id: String { rawValue }

        /// Never the raw identifier (`docs/IMPROVEMENTS-2026-09-16.md` §1.1 item 5).
        var name: String {
            switch self {
            case .unstated: return "Not said"
            case .right: return "Right"
            case .left: return "Left"
            }
        }
    }

    static let handKey = "shooter.shootingHand"

    static var shootingHand: ShootingHand {
        get { ShootingHand(rawValue: UserDefaults.standard.string(forKey: handKey) ?? "") ?? .unstated }
        set {
            if newValue == .unstated { UserDefaults.standard.removeObject(forKey: handKey) }
            else { UserDefaults.standard.set(newValue.rawValue, forKey: handKey) }
        }
    }

    static let handPrompt = "Used for the wording of cues and the left/right convention on the rim map. Nothing measured depends on it."
}
