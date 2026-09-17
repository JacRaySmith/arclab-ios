import ShotGeometry
import SwiftUI

/// The footwork card on the shot result: what the feet did, and — just as prominently — what this
/// camera position could not see them do.
///
/// The second half is the point. A side-on clip carries the gather, the stagger and the travel
/// toward the rim, and carries *nothing* about stance width or sideways drift. A card that silently
/// omitted the missing half would read as "your width is fine". This one names every refusal and
/// says which camera position would answer it (`docs/DESIGN-FOOTWORK-2026-09-15.md`).
struct FootworkCardView: View {
    let body_: ShotBodyResult?
    var unavailableReason: String?

    var body: some View {
        GroupBox("Footwork") {
            VStack(alignment: .leading, spacing: 10) {
                if let m = body_?.footwork {
                    if let why = m.unavailableReason {
                        note(why)
                    } else {
                        pattern(m)
                        Divider()
                        timing(m)
                        Divider()
                        stance(m)
                        Divider()
                        travel(m)
                        Divider()
                        blindSpots(m)
                        provenance(m)
                    }
                } else {
                    note(unavailableReason ?? "not measured: the body-pose stage did not run for this shot, so the feet were never tracked")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Sections

    @ViewBuilder private func pattern(_ m: FootworkMetrics) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(m.pattern.title.capitalized).font(.headline)
                Spacer()
                if let n = m.stepCount.value {
                    Text("\(Int(n)) step\(Int(n) == 1 ? "" : "s") before the lift")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(m.patternReason).font(.caption).foregroundStyle(.secondary)
            if let first = m.firstFootDown {
                Text("\(first.rawValue.capitalized) foot down first"
                     + (m.firstFootDownIsShootingSide == true ? " — your shooting side." : (m.firstFootDownIsShootingSide == false ? " — your off side." : ".")))
                    .font(.caption)
            }
            let contactCount = m.contacts.count
            if contactCount > 0 {
                Text("\(contactCount) ground contact\(contactCount == 1 ? "" : "s") read from the ankles' image rows.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func timing(_ m: FootworkMetrics) -> some View {
        row("Gather (plant → release)", m.gatherSeconds, seconds)
        row("Take-off → release", m.liftToReleaseSeconds, seconds)
        row("Between the two steps", m.stepSeparationSeconds, seconds)
    }

    @ViewBuilder private func stance(_ m: FootworkMetrics) -> some View {
        row("Feet apart, as the camera sees them", m.ankleSeparationImage, stature)
        row("Stance width (side to side)", m.stanceWidth, stature)
        row("Stagger (front to back)", m.stanceStagger, statureSigned)
        row("Feet turned toward the rim", m.footAngleToRim, degrees)
    }

    @ViewBuilder private func travel(_ m: FootworkMetrics) -> some View {
        row("Rise, take-off → release", m.jumpRise, stature)
        row("Travel toward the rim", m.jumpForwardTravel, statureSigned)
        row("Drift sideways", m.hipDriftLateral, statureSigned)
        row("Drift toward the rim", m.hipDriftTowardRim, statureSigned)
    }

    /// Everything the view refused, gathered in one place so the absence is visible.
    @ViewBuilder private func blindSpots(_ m: FootworkMetrics) -> some View {
        let refused: [(String, String)] = [
            ("Stance width", m.stanceWidth.unavailableReason),
            ("Stagger", m.stanceStagger.unavailableReason),
            ("Sideways drift", m.hipDriftLateral.unavailableReason),
            ("Travel toward the rim", m.jumpForwardTravel.unavailableReason),
            ("Foot angle", m.footAngleToRim.unavailableReason),
        ].compactMap { name, why in why.map { (name, $0) } }

        if !refused.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("What this camera position could not see", systemImage: "eye.slash")
                    .font(.caption.bold())
                ForEach(refused, id: \.0) { name, why in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).font(.caption2.bold())
                        Text(why).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func provenance(_ m: FootworkMetrics) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let deg = m.viewAzimuth.degrees {
                Text(String(format: "Camera %.0f° off the direction you face, measured from your hip line this shot. Lengths are fractions of your own ankle-to-nose height, not metres.", deg))
            } else if let why = m.viewAzimuth.unavailableReason {
                Text("The camera's angle to you was not measured: \(why)")
            }
            ForEach(m.warnings, id: \.self) { Text($0) }
            ForEach(m.notes, id: \.self) { Text($0) }
        }
        .font(.caption2).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Rows

    private func row(_ label: String, _ v: FootworkValue, _ format: (Double) -> String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption)
            Spacer(minLength: 8)
            if let x = v.value {
                Text(format(x)).font(.caption.monospacedDigit())
            } else {
                Text("not measured").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func seconds(_ x: Double) -> String { String(format: "%.0f ms", 1000 * x) }
    private func stature(_ x: Double) -> String { String(format: "%.3f of your height", x) }
    private func statureSigned(_ x: Double) -> String { String(format: "%+.3f of your height", x) }
    private func degrees(_ x: Double) -> String { String(format: "%.0f°", x * 180 / .pi) }

    @ViewBuilder private func note(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The graded rules for one shot, against the drill ArcLab inferred from what it saw.
///
/// The drill is inferred, not asked for — the app has no drill picker yet — and the card says so,
/// because "you never stepped into this one" is only a fault if the drill wanted a step.
struct FootworkRulesView: View {
    let metrics: FootworkMetrics

    private var drill: FootworkDrill {
        switch metrics.pattern {
        case .stationary, .unknown: return .stationaryCatch
        case .hop, .oneTwo, .singleStep: return .catchAndShoot
        }
    }

    var body: some View {
        let e = FootworkEvaluation.evaluate(metrics, drill: drill, shootingSide: metrics.shootingSide)
        GroupBox("Footwork rules") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Graded as a \(drill.title.lowercased()) — ArcLab picked that from the step pattern it measured, not from what you were actually running.")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(e.summary).font(.subheadline)
                ForEach(e.findings) { f in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Circle().fill(colour(f.severity)).frame(width: 7, height: 7)
                            Text(f.headline).font(.caption)
                            Spacer(minLength: 4)
                            Text(f.isFolklore ? "folklore · \(f.grade.letter)" : f.grade.letter)
                                .font(.caption2.bold()).foregroundStyle(.secondary)
                        }
                        Text(f.detail).font(.caption2).foregroundStyle(.secondary)
                        Text(f.source).font(.caption2).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func colour(_ s: FootworkSeverity) -> Color {
        switch s {
        case .ok: return .green
        case .watch: return .orange
        case .fault: return .red
        case .unmeasured: return .secondary
        }
    }
}
