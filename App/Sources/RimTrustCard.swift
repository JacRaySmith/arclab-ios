import ShotGeometry
import SwiftUI

/// What the shooter is told when the rim they traced and the phone's own sense of down disagree —
/// and the honest ways out of it. Two related but distinct questions live here, never shown at once:
///
/// 1. **Only one rim exists** (no auto-found candidate, or it agreed with the trace): the trace
///    itself is far from gravity. `disagreement(...)` — retrace, or solve with the phone's own sense
///    of down, or keep the trace as it is.
/// 2. **Two rims existed and disagreed**: gravity already picked the auto-found one over the
///    shooter's active trace by more than `RimGravity.arbitrationMargin`. `arbitrationNotice(...)` —
///    says so, and offers the trace back. This case pre-empts the first: once gravity has resolved
///    the disagreement by switching candidates, there is nothing left for `disagreement(...)` to ask.
///
/// It says nothing at all while the active candidate agrees with gravity (under
/// `RimUpAgreement.tolerance`) or the two candidates are a near-tie (under `RimGravity.arbitrationMargin`)
/// — silence is the reward for a good trace. Neither card ever acts on its own: the trace stays
/// exactly as it was drawn until the shooter picks a button. The roll warning below needs no sensor
/// and shows up on imported clips too.
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
            if let headline = model.rimArbitrationHeadline, let message = model.rimArbitrationMessage {
                arbitrationNotice(headline: headline, message: message)
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

    /// Gravity chose the ring `RimFinder` found on its own over the shooter's active trace. Never
    /// shown alongside `disagreement(...)` above — one card, whichever question is the live one — and
    /// never shown at all when the trace was the better candidate: silence is the reward for a good
    /// trace.
    @ViewBuilder
    private func arbitrationNotice(headline: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(headline, systemImage: "scope")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Button { model.useTracedRimOverArbitration() } label: {
                Label("Use my trace instead", systemImage: "hand.draw")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Text(model.rimArbitrationMarginCaption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}
