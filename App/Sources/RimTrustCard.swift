import ShotGeometry
import SwiftUI

/// What the shooter is told when the rim they traced and the phone's own sense of down disagree —
/// and the two honest ways out of it.
///
/// It says nothing at all while the two agree (under `RimUpAgreement.tolerance`), and it never acts
/// on its own: the trace stays exactly as it was drawn until the shooter picks one of the buttons.
/// The second warning below needs no sensor and shows up on imported clips too.
struct RimTrustCard: View {
    @Bindable var model: AnalysisModel
    /// What "trace the ring again" should do here. Nil on the screens that are not the marking
    /// screen; they push the marking screen instead.
    var retrace: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let headline = model.rimTrustHeadline, let message = model.rimTrustMessage,
               !model.rimTrustAnswered {
                disagreement(headline: headline, message: message)
            }
            ForEach(model.rimTrustWarnings, id: \.self) { warning in
                Label {
                    Text(warning).font(.footnote)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            }
            if model.rimTrustAnswered, model.calibration != nil {
                Label(model.rimUpProvenance, systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func disagreement(headline: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(headline, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if let retrace {
                Button { retrace() } label: {
                    Label("Trace the ring again", systemImage: "circle.dashed")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                NavigationLink {
                    RimMarkingView(model: model)
                } label: {
                    Label("Trace the ring again", systemImage: "circle.dashed")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            if model.measuredCameraUp != nil {
                Button { model.useMeasuredUpForRim() } label: {
                    Label("Use the phone's sense of down", systemImage: "arrow.down.to.line")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Button { model.keepTracedUpForRim() } label: {
                Text("Keep my trace as it is").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Text("Keeping it changes nothing and measures the session as it stands; the session's record will say which of the two was used.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}
