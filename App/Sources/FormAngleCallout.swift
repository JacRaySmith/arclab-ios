import ShotGeometry
import SwiftUI
import simd

// ================================================================================================
// MARK: - Angles on the body, on demand (item 20) — and the scrim everything over the scene sits on
// ================================================================================================
//
// Tap a joint, get that joint's angle at the instant on screen with the block's own spread beside
// it; tap it again and it is gone. Nothing is drawn permanently, which is the whole point of the
// item: the 3-D screen is for shapes, and a number appears only when it is asked for.
//
// Every number over the scene sits on an **opaque scrim** (the outside research's legibility rule,
// §7: ≥ 80 % opaque behind text over footage or a 3-D scene — no glass). The scene's ground is a
// fixed dark, so the scrim is dark too and the type on it is light in both appearances.

// MARK: - The scrim

enum FormSceneChrome {
    /// ≥ 80 % opaque. Not a material: a material over a moving 3-D scene is exactly what the
    /// research says makes a number unreadable.
    static let scrim = Color(red: 0.07, green: 0.08, blue: 0.10).opacity(0.88)
    static let scrimStroke = Color.white.opacity(0.14)
    static let text = Color.white
    static let secondaryText = Color.white.opacity(0.72)
    static let warningText = Color(red: 1.0, green: 0.76, blue: 0.34)
    /// The scene's own ground, matched by `FormSceneModel.background`.
    static let sceneBackground = Color(red: 0.10, green: 0.11, blue: 0.13)
}

private struct FormSceneScrim: ViewModifier {
    var corner: CGFloat
    func body(content: Content) -> some View {
        content
            .foregroundStyle(FormSceneChrome.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(FormSceneChrome.scrim, in: RoundedRectangle(cornerRadius: corner))
            .overlay(RoundedRectangle(cornerRadius: corner).strokeBorder(FormSceneChrome.scrimStroke))
    }
}

extension View {
    /// Put this over the 3-D scene: an opaque ≥ 80 % plate, so the numbers on it stay readable at
    /// every camera angle and over every pose.
    func formSceneScrim(corner: CGFloat = 10) -> some View { modifier(FormSceneScrim(corner: corner)) }
}

// MARK: - Which joints can be tapped

enum FormTappableJoint {
    /// Elbow, knee, shoulder, hip, wrist — both sides. The joints the item names, and no others:
    /// an ankle or a nose has no angle in this model and tapping one would only promise a number.
    static let names: [String] = [
        Body2DPoint.leftElbow, Body2DPoint.rightElbow,
        Body2DPoint.leftKnee, Body2DPoint.rightKnee,
        Body2DPoint.leftShoulder, Body2DPoint.rightShoulder,
        Body2DPoint.leftHip, Body2DPoint.rightHip,
        Body2DPoint.leftWrist, Body2DPoint.rightWrist,
    ]

    static func indices(in joints: [String]) -> [Int] {
        names.compactMap { joints.firstIndex(of: $0) }
    }

    /// "rightElbow" → "Right elbow".
    static func pretty(_ name: String) -> String {
        var out = ""
        for c in name {
            if c.isUppercase && !out.isEmpty { out += " " + c.lowercased() } else { out.append(c) }
        }
        return out.prefix(1).uppercased() + out.dropFirst()
    }

    /// The three joints whose angle this one is, and the angle track the model files it under.
    ///
    /// The wrist joined the list in 1.3: the form now carries the hand plate's two knuckles, so
    /// elbow → wrist → mid-knuckle is a real angle in the same body frame as the rest. It is
    /// available only on the samples where the hand detector actually saw the knuckles, and the
    /// callout prints the model's own reason where it did not.
    static func angleDefinition(for joint: String) -> (a: String, vertex: String, b: String, track: String, described: String)? {
        let side = joint.hasPrefix("left") ? "left" : "right"
        func s(_ part: String) -> String { side + part }
        if joint.hasSuffix("Elbow") {
            return (s("Shoulder"), joint, s("Wrist"), s("Elbow"), "shoulder → elbow → wrist")
        }
        if joint.hasSuffix("Knee") {
            return (s("Hip"), joint, s("Ankle"), s("Knee"), "hip → knee → ankle")
        }
        if joint.hasSuffix("Hip") {
            return (s("Shoulder"), joint, s("Knee"), s("Hip"), "shoulder → hip → knee")
        }
        if joint.hasSuffix("Shoulder") {
            return (s("Elbow"), joint, s("Hip"), s("ShoulderElevation"), "elbow → shoulder → hip (how far the arm is raised from the trunk)")
        }
        if joint.hasSuffix("Wrist") {
            return (s("Elbow"), joint, s("IndexMCP"), joint,
                    "elbow → wrist → the midpoint of the index and little knuckles (the hand's own pointing direction). 180° is a hand in line with the forearm; less is flexion or extension, and this interior angle does not say which — the shot record's signed wrist flexion does")
        }
        return nil
    }
}

// MARK: - What the callout says

/// Everything the card shows, worked out once. Every field is either a number with its unit and its
/// provenance, or nil with the model's own reason — never a blank.
struct FormJointCallout: Sendable {
    var joint: String
    var title: String
    var whenLabel: String

    var shotDegrees: Double?
    var shotUnavailableReason: String?
    var modelMeanDegrees: Double?
    var modelSDDegrees: Double?
    var modelN: Int = 0
    var modelUnavailableReason: String?
    var deviationSDs: Double?

    /// 1σ of this joint's position in the ghost's own block, per body axis, already in display units.
    var spreadText: String?
    var spreadUnavailableReason: String?

    var inferredNote: String?
    var provenance: String
    var modelLabel: String

    static func build(joint: String, joints: [String],
                      shotPositions: [SIMD3<Double>?]?, shotInferred: [Bool],
                      model: FormModel, modelLabel: String, sampleIndex: Int,
                      whenLabel: String) -> FormJointCallout {
        let definition = FormTappableJoint.angleDefinition(for: joint)
        var c = FormJointCallout(joint: joint, title: FormTappableJoint.pretty(joint), whenLabel: whenLabel,
                                 provenance: definition.map { "Angle at the \(FormTappableJoint.pretty(joint).lowercased()): \($0.described), measured in the shooter's own body frame. Degrees." }
                                    ?? "This model carries the eight joint angles a skeleton of shoulders, elbows, hips, knees and ankles can form.",
                                 modelLabel: modelLabel)

        // ---- is this joint even measured? ----
        let jointIndex = joints.firstIndex(of: joint)
        if let j = jointIndex, shotInferred.indices.contains(j), shotInferred[j] {
            c.inferredNote = "This joint was never seen by the tracker on this shot: it is mirrored from the other side of the body, so no angle is read off it."
        }

        guard let definition else {
            c.shotUnavailableReason = "there is no wrist angle in this model — it needs the hand landmarks, which are 2-D and are not kept in the form. The body player's own readout has a wrist-flexion track where the file measured one."
            c.modelUnavailableReason = c.shotUnavailableReason
            return c
        }

        // ---- this shot's angle, from the sample on screen ----
        if c.inferredNote != nil {
            c.shotUnavailableReason = "mirrored, not measured"
        } else if let p = shotPositions {
            let a = FormPhaseStops.point(joints, p, definition.a)
            let v = FormPhaseStops.point(joints, p, definition.vertex)
            let b = FormPhaseStops.point(joints, p, definition.b)
            if let a, let v, let b, let theta = FormPhaseStops.angle(a, v, b) {
                c.shotDegrees = theta * 180 / .pi
            } else {
                let missing = [(definition.a, a), (definition.vertex, v), (definition.b, b)]
                    .filter { $0.1 == nil }.map { FormTappableJoint.pretty($0.0).lowercased() }
                c.shotUnavailableReason = "this shot has no \(missing.joined(separator: " and no ")) at this instant, so the angle cannot be formed"
            }
        } else {
            c.shotUnavailableReason = "this screen was not opened from a single shot, so there is no shot angle — only the block's"
        }

        // ---- the block's own mean and spread at this instant ----
        if let track = model.angles.first(where: { $0.name == definition.track }) {
            let i = min(max(0, sampleIndex), max(0, model.sampleCount - 1))
            c.modelMeanDegrees = track.meanDegrees.indices.contains(i) ? track.meanDegrees[i] : nil
            c.modelSDDegrees = track.sdDegrees.indices.contains(i) ? track.sdDegrees[i] : nil
            c.modelN = track.n.indices.contains(i) ? track.n[i] : 0
            if c.modelMeanDegrees == nil {
                c.modelUnavailableReason = track.unavailableReason
                    ?? "\(modelLabel) has no \(definition.track) at this instant"
            } else if c.modelSDDegrees == nil {
                c.modelUnavailableReason = "\(modelLabel) has a mean here but no spread: a spread needs at least three shots"
            }
            if track.usesInferredJoints {
                c.inferredNote = (c.inferredNote.map { $0 + " " } ?? "")
                    + "In \(modelLabel) this angle uses at least one joint that was mirrored rather than seen."
            }
            if let v = c.shotDegrees, let m = c.modelMeanDegrees, let sd = c.modelSDDegrees, sd > 1e-6 {
                c.deviationSDs = (v - m) / sd
            }
        } else {
            c.modelUnavailableReason = model.unavailableReason
                ?? "\(modelLabel) carries no \(definition.track) track"
        }

        // ---- the ellipsoid: 1σ of where this joint sat ----
        if let j = jointIndex, let s = model.samples.indices.contains(sampleIndex) ? model.samples[sampleIndex] : nil {
            if let spread = s.spread(j) {
                let n = s.n.indices.contains(j) ? s.n[j] : model.shots
                c.spreadText = spreadLine(spread, unit: model.unit, n: n)
            } else {
                c.spreadUnavailableReason = model.shots < 3
                    ? "\(modelLabel) has \(model.shots) shot\(model.shots == 1 ? "" : "s"): a spread needs at least 3"
                    : "\(modelLabel) has no spread for this joint at this instant"
            }
        } else {
            c.spreadUnavailableReason = model.unavailableReason ?? "\(modelLabel) does not carry this joint"
        }
        return c
    }

    /// 1σ per body axis: x toward the rim, y across the body, z up. Centimetres when the form is in
    /// metres; otherwise fractions of the shooter's own standing height, which is what the form is in.
    private static func spreadLine(_ s: SIMD3<Double>, unit: FormLengthUnit, n: Int) -> String {
        func v(_ x: Double) -> String {
            unit == .metres ? String(format: "%.1f cm", x * 100) : String(format: "%.3f statures", x)
        }
        return "1σ \(v(s.x)) toward the rim · \(v(s.y)) across · \(v(s.z)) up (n \(n))"
    }
}

// MARK: - The card

struct FormJointCalloutView: View {
    var callout: FormJointCallout
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(callout.title).font(.subheadline.bold())
                Spacer(minLength: 10)
                Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(FormSceneChrome.secondaryText)
                    .accessibilityLabel("Close the joint callout")
            }
            Text("at the \(callout.whenLabel)").font(.caption2).foregroundStyle(FormSceneChrome.secondaryText)

            if let d = callout.shotDegrees {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(format: "%.0f°", d)).font(.title3.monospacedDigit().bold())
                    if let z = callout.deviationSDs {
                        Text(String(format: "%+.1f SD", z))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(abs(z) > 2 ? FormSceneChrome.warningText : FormSceneChrome.secondaryText)
                    }
                }
            } else if let why = callout.shotUnavailableReason {
                Text("not measured — " + why).font(.caption2).foregroundStyle(FormSceneChrome.secondaryText)
            }

            if let m = callout.modelMeanDegrees {
                Text(callout.modelSDDegrees.map { String(format: "%@: %.0f ± %.0f° (n %d)", callout.modelLabel, m, $0, callout.modelN) }
                     ?? String(format: "%@: %.0f° (n %d)", callout.modelLabel, m, callout.modelN))
                    .font(.caption.monospacedDigit()).foregroundStyle(FormSceneChrome.secondaryText)
            } else if let why = callout.modelUnavailableReason {
                Text(why).font(.caption2).foregroundStyle(FormSceneChrome.secondaryText)
            }

            if let s = callout.spreadText {
                Text(s).font(.caption2.monospacedDigit()).foregroundStyle(FormSceneChrome.secondaryText)
            } else if let why = callout.spreadUnavailableReason {
                Text("no spread — " + why).font(.caption2).foregroundStyle(FormSceneChrome.secondaryText)
            }

            if let n = callout.inferredNote {
                Text(n).font(.caption2).foregroundStyle(FormSceneChrome.warningText)
            }
            Text(callout.provenance).font(.caption2).foregroundStyle(FormSceneChrome.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .formSceneScrim()
        .accessibilityElement(children: .combine)
    }
}
