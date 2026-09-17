import ShotGeometry
import ShotVideo
import SwiftUI
import UIKit

/// One shot's result: the arc drawn over the release frame, the numbers with their verdict, the pose
/// angles, and the rim map. Every value that could not be measured says so and gives the analyzer's
/// own reason. The same screen serves the single-shot flow and a shot picked out of a session.
struct ResultsView: View {
    let context: ShotResultContext
    /// The block this shot belongs to, for the 3-D form comparison — every accepted shot's form in
    /// the session the screen was opened from. Empty outside a session, and then the form screen
    /// shows this shot alone and says the block has none.
    var blockForms: [ShotForm] = []
    var blockLabel: String = "This block"
    var earlierSessions: [SavedSession] = []

    @State private var frame: FrameImage?
    @State private var loading = false
    @State private var loadError: String?
    @State private var showDetections = true

    private func deg(_ rad: Double) -> Double { rad * 180 / .pi }

    var body: some View {
        ScrollView {
            let a = context.analysis
            VStack(alignment: .leading, spacing: 18) {
                if let v = context.verdict { verdictCard(v) }
                arcCard(a)
                gravityCard(a)
                metricsCard(a)
                poseCard
                bodyCard
                FootworkCardView(body_: context.body, unavailableReason: context.bodyUnavailableReason)
                if let fw = context.body?.footwork, fw.unavailableReason == nil { FootworkRulesView(metrics: fw) }
                formLink
                GroupBox("Rim map") {
                    RimMapView(depthPastFrontRim: a.metrics.depthPastFrontRim,
                               depthUnavailableReason: a.metrics.entryAngleUnavailableReason,
                               depthClass: a.metrics.depthClass,
                               lateral: a.metrics.lateralDeviation,
                               viewClass: a.confidence.viewClass,
                               ballDiameter: BallSize.size7.diameter)
                }
                qualityCard(a)
                warningsCard(a)
                notesCard
            }
            .padding(.horizontal)
            .padding(.bottom, 28)
        }
        .navigationTitle(context.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadReleaseFrame() }
    }

    // MARK: Session verdict and inferred outcome

    private func verdictCard(_ v: ShotAcceptance.Verdict) -> some View {
        // Two words, with the whole sentence directly underneath: "accept / gravity 9.35 within 8 %"
        // was the verdict wearing its own arithmetic.
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VerdictChip(wording: VerdictWording.of(v))
                    Spacer()
                    if let o = context.outcome {
                        Text(o.outcome.rawValue).font(.caption.bold())
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(outcomeColor(o.outcome).opacity(0.18), in: Capsule())
                            .foregroundStyle(outcomeColor(o.outcome))
                    }
                }
                if let reason = v.reason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("This shot is counted in the block summary.").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let o = context.outcome {
                    Text("Outcome \(o.outcome.rawValue) — \(o.reason)\(o.strength.map { " (\($0))" } ?? "").")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func outcomeColor(_ o: InferredOutcome) -> Color {
        switch o {
        case .make: return .green
        case .miss: return .red
        case .unknown: return .secondary
        }
    }

    // MARK: Arc over the frame

    @ViewBuilder private func arcCard(_ a: ShotAnalysis) -> some View {
        let overlay = ShotOverlay(analysis: a, samples: context.samples, rimPoints: context.rimPoints,
                                  intrinsics: context.intrinsics)
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if let frame {
                    GeometryReader { geo in
                        let fit = ImageFit(imageSize: frame.pixelSize, viewSize: geo.size)
                        ZStack {
                            Image(uiImage: frame.image).resizable().aspectRatio(contentMode: .fit)
                            Canvas { ctx, _ in draw(ctx, fit: fit, overlay: overlay) }
                        }
                    }
                    .aspectRatio(frame.pixelSize.width / max(frame.pixelSize.height, 1), contentMode: .fit)
                } else {
                    Rectangle().fill(.quaternary).aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .overlay { loading ? AnyView(ProgressView()) : AnyView(Text(loadError ?? "no frame").font(.footnote).foregroundStyle(.secondary)) }
                }
            }
            HStack(spacing: 12) {
                legend(.orange, "fitted parabola")
                legend(.green, "rim points")
                legend(.white, "detections")
                legend(.red, "release")
            }
            .font(.caption2)
            Toggle("Show every detection", isOn: $showDetections).font(.caption)
            if let frame {
                Text(String(format: "release frame: %.3f s file time (%.3f s real, × %.2f slow-motion factor)", frame.pts, a.confidence.releaseTime, context.timeScale))
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private func draw(_ ctx: GraphicsContext, fit: ImageFit, overlay: ShotOverlay) {
        for p in overlay.rim { ctx.dot(fit.point(p), radius: 2.5, color: .green) }
        if let rc = overlay.rimCenter { ctx.ring(fit.point(rc), radius: 5, color: .green, lineWidth: 1) }
        if showDetections {
            for p in overlay.detections { ctx.dot(fit.point(p), radius: 1.8, color: .white.opacity(0.85)) }
        }
        for p in overlay.flight { ctx.ring(fit.point(p), radius: 3.5, color: .white.opacity(0.9), lineWidth: 1) }
        if overlay.parabola.count > 1 {
            var path = Path()
            path.move(to: fit.point(overlay.parabola[0]))
            for p in overlay.parabola.dropFirst() { path.addLine(to: fit.point(p)) }
            ctx.stroke(path, with: .color(.orange), lineWidth: 3)
        }
        if let r = overlay.releasePoint {
            ctx.ring(fit.point(r), radius: 8, color: .red, lineWidth: 2)
            ctx.ring(fit.point(r), radius: 11, color: .red, lineWidth: 1)
        }
        if let e = overlay.windowEndPoint { ctx.ring(fit.point(e), radius: 8, color: .orange, lineWidth: 2) }
    }

    // MARK: Gravity gate

    private func gravityCard(_ a: ShotAnalysis) -> some View {
        let c = a.confidence
        let color: Color = c.gravityVerdict == .accept ? .green : (c.gravityVerdict == .lowConfidence ? .orange : .red)
        return GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(String(format: "g_fit %.2f m/s²", c.gFit)).font(.title3.monospaced().bold())
                    Spacer()
                    Text(verdictLabel(c.gravityVerdict))
                        .font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(color.opacity(0.18), in: Capsule())
                        .foregroundStyle(color)
                }
                Text(GravityGate.explain(gFit: c.gFit))
                    .font(.footnote.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("The fit solves for gravity instead of assuming it: g is the check on the scale and the timing, never an input. Within 8 % is accepted, within 20 % is low confidence, beyond that the shot is rejected.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func verdictLabel(_ v: GravityVerdict) -> String {
        switch v {
        case .accept: return "ACCEPT"
        case .lowConfidence: return "LOW CONFIDENCE"
        case .reject: return "REJECT"
        }
    }

    // MARK: Metrics

    private func metricsCard(_ a: ShotAnalysis) -> some View {
        let m = a.metrics
        return GroupBox("Measurements") {
            VStack(alignment: .leading, spacing: 8) {
                metric("Release angle", m.release.map { String(format: "%.1f°", $0.angleDegrees) }, m.releaseUnavailableReason)
                metric("Release height", m.release.map { String(format: "%.2f m", $0.height) }, m.releaseUnavailableReason)
                metric("Release speed", m.release.map { String(format: "%.2f m/s", $0.speed) }, m.releaseUnavailableReason)
                metric("Release distance", m.release.map { String(format: "%.2f m", $0.distance) }, m.releaseUnavailableReason)
                metric("Entry angle", m.entryAngleDegrees.map { String(format: "%.1f°", $0) }, m.entryAngleUnavailableReason)
                metric("Apex height", m.apexHeight.map { String(format: "%.2f m", $0) }, "the fit never rises within the window")
                metric("Depth past front rim", m.depthPastFrontRim.map { String(format: "%.1f cm", $0 * 100) }, m.entryAngleUnavailableReason)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metric(_ label: String, _ value: String?, _ reason: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text(value ?? "not measured")
                    .font(value == nil ? .subheadline.italic() : .subheadline.monospaced().bold())
                    .foregroundStyle(value == nil ? .secondary : .primary)
            }
            if value == nil {
                Text(reason ?? "no reason was recorded by the analyzer")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Pose

    @ViewBuilder private var poseCard: some View {
        GroupBox("Body (2-D, camera side)") {
            VStack(alignment: .leading, spacing: 8) {
                if let p = context.pose {
                    if let angles = p.angles {
                        metric("Elbow at release", angles.elbowAtReleaseDegrees.map { String(format: "%.0f°", $0) },
                               "the shoulder, elbow or wrist on the \(angles.side == "l" ? "left" : "right") side was not confident on the release frame")
                        metric("Elbow, most extended near release", angles.elbowMaxNearReleaseDegrees.map { String(format: "%.0f°", $0) },
                               "no frame within ±6 pose frames of release carried a confident arm")
                        metric("Knee, deepest bend before release", angles.kneeMinimumDegrees.map { String(format: "%.0f°", $0) },
                               "the hip, knee or ankle was never confident in the 0.6 s before release")
                    } else {
                        metric("Elbow at release", nil, p.anglesUnavailableReason ?? p.releaseUnavailableReason)
                        metric("Knee, deepest bend before release", nil, p.anglesUnavailableReason ?? p.releaseUnavailableReason)
                    }
                    if let warning = p.viewWarning {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.caption2).foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        if let t = p.releaseFileTime {
                            Text(String(format: "release instant from the wrist: %.3f s file time (%.4f s real) — the analyzer used it instead of searching for the ramp",
                                        t, p.releaseRealTime ?? 0))
                        } else if let reason = p.releaseUnavailableReason {
                            Text("release instant not measured from the body: \(reason)")
                        }
                        ForEach(Array(p.notes.enumerated()), id: \.offset) { _, n in Text(n) }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("not measured: the body-pose stage did not run for this shot")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Body model (the fitted skeleton)

    /// One skeleton fitted to the whole shot, then read at the four points of the shot.
    ///
    /// What is shown here is what `docs/PHASE2-PREP.md` "Body model, iteration 2" measured as
    /// trustworthy at this subject size: the fitted joint angles (1.4–1.6°/frame of noise, at or below
    /// the 2-D floor), phase timing from the fitted wrist path, head steadiness from the 2-D nose
    /// (1.0 px/frame), and image-plane metres — but only once a standing height has set the scale.
    /// Everything transverse on a near-side view, and Vision's own 3-D angles, are refused upstream
    /// and arrive here as nil with the sentence that says why.
    @ViewBuilder private var bodyCard: some View {
        GroupBox("Body model") {
            VStack(alignment: .leading, spacing: 10) {
                if let b = context.body {
                    if let shot = b.bodyShot {
                        NavigationLink {
                            BodyPlayerView(title: "3-D body (experimental)", preloaded: shot, meanForm: nil, source: "results")
                        } label: {
                            Label("Play this shot as a 3-D body — experimental, \(shot.frames.count) frames", systemImage: "figure.basketball")
                        }
                    }
                    phaseTable(b)
                    Divider()
                    measureRow("Dip to release", b.dipToReleaseMilliseconds, "%.0f")
                    chainRow(b)
                    measureRow("Elbow extension, peak speed", b.elbowExtensionPeakRate, "%.0f")
                    measureRow("Knee extension, peak speed", b.kneeExtensionPeakRate, "%.0f")
                    measureRow("Knee, deepest bend (fitted)", b.kneeMinimum, "%.0f")
                    Divider()
                    measureRow("Jump height", b.jumpHeight, "%.2f")
                    measureRow("Dip depth, of your own height", b.dipDepthNormalised, "%.3f")
                    measureRow("Dip depth", b.dipDepthMetres, "%.2f")
                    measureRow("Head steadiness, of your own height", b.headStabilityNormalised, "%.4f")
                    measureRow("Head steadiness", b.headStabilityPx, "%.1f")
                    measureRow("Squareness (shoulder line)", b.shoulderLineYaw, "%.1f")
                    Divider()
                    measureRow("Hands found near release", b.handRateAtRelease, "%.2f")
                    bodyProvenance(b)
                } else {
                    Text(context.bodyUnavailableReason ?? "not measured: the body stage did not run for this shot")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The 3-D form: this shot's skeleton, and the block's mean form on top of it.
    @ViewBuilder private var formLink: some View {
        let model = blockForms.isEmpty
            ? FormModel.unavailable("this shot was not opened from a session, so there is no block to compare it with", label: blockLabel)
            : FormModel.build(forms: blockForms, label: blockLabel)
        NavigationLink {
            FormModelView(title: "3-D form", model: model, shot: context.body?.form,
                          source: "results", earlierSessions: earlierSessions)
        } label: {
            GroupBox {
                HStack {
                    Image(systemName: "figure.basketball").font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("3-D form").font(.subheadline.bold())
                        Text(formSubtitle(model)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    private func formSubtitle(_ model: FormModel) -> String {
        if context.body?.form == nil {
            return context.body?.formUnavailableReason
                ?? context.bodyUnavailableReason
                ?? "no 3-D form for this shot"
        }
        return model.isAvailable
            ? "this shot against the block's mean form, \(model.shots) shot\(model.shots == 1 ? "" : "s")"
            : "this shot's skeleton on its own"
    }

    private func phaseTable(_ b: ShotBodyResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Phase").frame(width: 104, alignment: .leading)
                Text("elbow").frame(maxWidth: .infinity, alignment: .trailing)
                Text("knee").frame(maxWidth: .infinity, alignment: .trailing)
                Text("hip").frame(maxWidth: .infinity, alignment: .trailing)
                Text("shoulder").frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.caption2).foregroundStyle(.secondary)
            ForEach(b.phases) { p in
                HStack {
                    Text(p.name).frame(width: 104, alignment: .leading)
                    ForEach(Array([p.elbow, p.knee, p.hip, p.shoulderElevation].enumerated()), id: \.offset) { _, m in
                        Text(m.degrees.map { String(format: "%.0f°", $0) } ?? "—")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .foregroundStyle(m.isAvailable ? .primary : .secondary)
                    }
                }
                .font(.caption.monospacedDigit())
                if let why = p.unavailableReason {
                    Text("\(p.name.lowercased()): \(why)").font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text(String(format: "Angles of one skeleton fitted to the whole shot, read at each phase. Phase times came from the %@. These are associated with how a shot is built, not scored against a target; an absolute angle from one camera is only good to about ±25°%@, so read your own shot-to-shot change.",
                        b.phaseSignal,
                        b.elbowJitterDegrees.map { String(format: ", and this fit moves %.1f° between sampled frames", $0) } ?? ""))
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(b.phaseNotes.enumerated()), id: \.offset) { _, n in
                Text(n).font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private func chainRow(_ b: ShotBodyResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Order of the drive").font(.subheadline)
                Spacer()
                Text(b.chainOrder.isEmpty ? "not measured" : b.chainOrder.joined(separator: " → "))
                    .font(b.chainOrder.isEmpty ? .subheadline.italic() : .subheadline.monospaced())
                    .foregroundStyle(b.chainOrder.isEmpty ? .secondary : .primary)
                    .multilineTextAlignment(.trailing)
            }
            if let why = b.chainUnavailableReason {
                Text(why).font(.caption2).foregroundStyle(.secondary)
            } else if let text = b.chainText {
                Text(text).font(.caption2.monospaced()).foregroundStyle(.secondary)
                Text(String(format: "One sampled frame is %.0f ms of real time, so a gap at or below that is the resolution of the video and not a measurement.", b.frameFloorMilliseconds))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(b.chainMissing.sorted(by: { $0.key < $1.key }), id: \.key) { joint, why in
                Text("\(joint): \(why)").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func measureRow(_ label: String, _ m: BodyMeasure, _ format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.subheadline)
                Spacer()
                Text(m.isAvailable ? m.describe(format) : "not measured")
                    .font(m.isAvailable ? .subheadline.monospaced() : .subheadline.italic())
                    .foregroundStyle(m.isAvailable ? .primary : .secondary)
            }
            if !m.isAvailable, let why = m.unavailableReason {
                Text(why).font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func bodyProvenance(_ b: ShotBodyResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "%d frames analysed over %.2f s of real time (every %d%@ frame), a body on %d of them, hands on %d. %@ Reprojection %@. Vision %.1f s + fit %.2f s.",
                        b.framesAnalysed, b.windowEndReal - b.windowStartReal, b.everyNthFrame,
                        b.everyNthFrame == 1 ? "" : "nd", b.framesWith2D, b.framesWithHands,
                        b.scaleNote, b.reprojectionRMSPx.describe("%.2f"), b.visionSeconds, b.fitSeconds))
            ForEach(Array(b.warnings.enumerated()), id: \.offset) { _, w in
                Label(w, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.caption2).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Quality / provenance

    private func qualityCard(_ a: ShotAnalysis) -> some View {
        let c = a.confidence
        return GroupBox("How well it was seen") {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Camera view", value: String(format: "%@, %.0f° from side", c.viewClass.rawValue, deg(c.viewAngle)))
                LabeledContent("Reprojection RMS", value: String(format: "%.2f px", c.rmsPx))
                LabeledContent("Samples in the fit", value: "\(c.nInliers) inliers of \(c.nDetections)")
                LabeledContent("Flight span", value: String(format: "%.2f s real", c.flightSpan))
                LabeledContent("Samples after apex", value: "\(c.samplesAfterApex)")
                LabeledContent("Azimuth σ", value: String(format: "%.1f°", deg(c.azimuthSigma)))
                LabeledContent("Release observed", value: c.releaseObserved ? "yes" : "no")
                LabeledContent("Calibration", value: {
                    switch c.calibrationPath {
                    case .rimEllipse: return "the rim's ellipse"
                    case .backboard: return "the backboard"
                    case .ballScale: return "the ball's size (approximate)"
                    case .none: return "none"
                    }
                }())
                if let w = context.window {
                    LabeledContent("Window analysed", value: String(format: "%.2f → %.2f s file time", w.lowerBound, w.upperBound))
                }
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func warningsCard(_ a: ShotAnalysis) -> some View {
        if !a.confidence.warnings.isEmpty {
            GroupBox("Warnings (\(a.confidence.warnings.count))") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(a.confidence.warnings.enumerated()), id: \.offset) { _, w in
                        Label(w, systemImage: "exclamationmark.triangle").font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    @ViewBuilder private var notesCard: some View {
        if !context.notes.isEmpty {
            GroupBox("Where the numbers came from") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(context.notes.enumerated()), id: \.offset) { _, n in
                        Text("• " + n).font(.caption2).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    // MARK: Frame

    private func loadReleaseFrame() async {
        guard frame == nil else { return }
        loading = true
        let url = context.clipURL
        let t = context.analysis.confidence.releaseTime * context.timeScale     // real seconds → file time
        do {
            frame = try await Task.detached(priority: .userInitiated) { try await FrameLoader.frame(url: url, time: t) }.value
        } catch {
            loadError = "release frame at \(String(format: "%.2f", t)) s: \(error)"
        }
        loading = false
    }
}

/// The single-shot flow's entry into `ResultsView`: shows the placeholder when nothing has been analysed.
struct SingleShotResultsView: View {
    var model: AnalysisModel

    var body: some View {
        if let context = model.resultContext {
            ResultsView(context: context)
        } else {
            ContentUnavailableView("No analysed shot", systemImage: "chart.line.uptrend.xyaxis",
                                   description: Text("Pick a window and run the analyzer first."))
        }
    }
}
