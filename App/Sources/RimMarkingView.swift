import ShotGeometry
import ShotVideo
import SwiftUI
import UIKit

/// Step 1: show one frame, tap ≥ 6 points around the ring, calibrate.
///
/// The points are stored in decoded-image pixels — the same coordinates the detector reports — so
/// the rim the user marked and the ball the analyzer finds live in one coordinate system.
struct RimMarkingView: View {
    @Bindable var model: AnalysisModel

    @State private var time: Double = 0
    @State private var frame: FrameImage?
    @State private var loading = false
    @State private var loadError: String?

    private var duration: Double { max(model.fileDuration, 0.001) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                frameArea
                scrubber
                pointControls
                calibrationBlock
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .navigationTitle("Mark the rim")
        .navigationBarTitleDisplayMode(.inline)
        .task { if frame == nil { await load(at: model.rimFrameTime ?? time) } }
    }

    // MARK: Frame + taps

    @ViewBuilder private var frameArea: some View {
        ZStack {
            if let frame {
                GeometryReader { geo in
                    let fit = ImageFit(imageSize: frame.pixelSize, viewSize: geo.size)
                    ZStack {
                        Image(uiImage: frame.image).resizable().aspectRatio(contentMode: .fit)
                        Canvas { ctx, _ in draw(ctx, fit: fit) }
                    }
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { value in
                        let p = fit.pixel(value.location)
                        guard fit.contains(pixel: p) else { return }
                        model.rimPoints.append(SIMD2(Double(p.x), Double(p.y)))
                        model.calibration = nil
                        model.calibrationError = nil
                        model.rimFrameTime = frame.pts
                    })
                }
                .aspectRatio(frame.pixelSize.width / max(frame.pixelSize.height, 1), contentMode: .fit)
            } else {
                Rectangle().fill(.quaternary).aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay { loading ? AnyView(ProgressView()) : AnyView(Text("no frame").foregroundStyle(.secondary)) }
            }
        }
        .overlay(alignment: .topLeading) {
            if let frame {
                Text(String(format: "frame at %.3f s file time · %.0f × %.0f px", frame.pts, frame.pixelSize.width, frame.pixelSize.height))
                    .font(.caption2.monospaced())
                    .padding(4)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .padding(6)
            }
        }
        if let loadError {
            Text(loadError).font(.footnote).foregroundStyle(.red)
        }
    }

    private func draw(_ ctx: GraphicsContext, fit: ImageFit) {
        if let cal = model.calibration {
            var path = Path()
            for i in 0...180 {
                let phi = Double(i) / 180 * 2 * .pi
                let p = fit.point(cal.ellipse.point(at: phi))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            ctx.stroke(path, with: .color(.cyan), lineWidth: 2)
            ctx.ring(fit.point(cal.ellipse.center), radius: 4, color: .cyan)
        }
        for (i, p) in model.rimPoints.enumerated() {
            let v = fit.point(p)
            let isLast = i == model.rimPoints.count - 1
            ctx.dot(v, radius: isLast ? 5 : 3.5, color: isLast ? .yellow : .green)
        }
    }

    // MARK: Scrubber

    private var scrubber: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Frame time").font(.subheadline)
                Spacer()
                Text(String(format: "%.2f s of %.2f s file time", time, duration)).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Slider(value: $time, in: 0...duration) { editing in
                if !editing { Task { await load(at: time) } }
            }
            HStack {
                Button("−1 s") { time = max(0, time - 1); Task { await load(at: time) } }
                Button("+1 s") { time = min(duration, time + 1); Task { await load(at: time) } }
                Spacer()
                Button {
                    Task { await load(at: time) }
                } label: {
                    if loading { ProgressView().controlSize(.small) } else { Text("Load frame") }
                }
                .disabled(loading)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: Points

    private var pointControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                if let frame, let last = model.rimPoints.last {
                    Loupe(frame: frame, pixel: CGPoint(x: last.x, y: last.y))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(model.rimPoints.count) point\(model.rimPoints.count == 1 ? "" : "s") marked")
                        .font(.headline)
                    Text("Tap around the *inside* of the ring — 6 or more, spread all the way round. The loupe shows the last point; nudge it a pixel at a time.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button {
                        guard let frame else { return }
                        model.clearRim()
                        Task { await model.findRimAutomatically(frameTimes: [frame.pts]) }
                    } label: {
                        Label(model.rimFinding ? "Looking…" : "Find the ring on this frame", systemImage: "scope")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(frame == nil || model.rimFinding)
                    if let note = model.rimFindNote { Text(note).font(.caption2).foregroundStyle(.orange) }
                    if !model.rimPoints.isEmpty {
                        HStack(spacing: 10) {
                            nudge("arrow.left", dx: -1, dy: 0)
                            nudge("arrow.right", dx: 1, dy: 0)
                            nudge("arrow.up", dx: 0, dy: -1)
                            nudge("arrow.down", dx: 0, dy: 1)
                        }
                    }
                    HStack {
                        Button("Undo point") { if !model.rimPoints.isEmpty { model.rimPoints.removeLast(); model.calibration = nil } }
                            .disabled(model.rimPoints.isEmpty)
                        Button("Clear", role: .destructive) { model.clearRim() }
                            .disabled(model.rimPoints.isEmpty)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            Button {
                model.calibrateRim()
            } label: {
                Label("Calibrate", systemImage: "circle.dashed").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.rimPoints.count < 6)
        }
    }

    private func nudge(_ system: String, dx: Double, dy: Double) -> some View {
        Button { 
            guard var p = model.rimPoints.last else { return }
            p.x += dx; p.y += dy
            model.rimPoints[model.rimPoints.count - 1] = p
            model.calibration = nil
        } label: { Image(systemName: system) }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: Calibration result

    @ViewBuilder private var calibrationBlock: some View {
        if let err = model.calibrationError {
            GroupBox("Calibration failed") {
                Text(err).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        if let cal = model.calibration {
            GroupBox("Rim calibration") {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("Camera → rim", value: String(format: "%.2f m", cal.distanceToRim))
                    LabeledContent("Rim above camera", value: String(format: "%.2f m", cal.rimHeightAboveCamera))
                    LabeledContent("Axis ratio", value: String(format: "%.3f", cal.ellipse.axisRatio))
                    LabeledContent("Ellipse residual", value: String(format: "%.2f px", cal.ellipseResidualPx))
                    LabeledContent("Pose ambiguity", value: String(format: "%.1f°", cal.ambiguityAngle * 180 / .pi))
                    LabeledContent("Rim diameter used", value: String(format: "%.4f m", cal.rimDiameterUsed))
                    LabeledContent("Camera pitch / roll", value: String(format: "%.1f° / %.1f°", cal.pitch * 180 / .pi, cal.roll * 180 / .pi))
                    if cal.warnings.isEmpty {
                        Label("no warnings", systemImage: "checkmark.seal").font(.footnote).foregroundStyle(.green)
                    } else {
                        ForEach(Array(cal.warnings.enumerated()), id: \.offset) { _, w in
                            Label(w, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                        }
                    }
                    Text("A flat axis ratio means the camera sits near rim height: the pose is weakly determined there. The cyan ellipse is the fit — check it against the ring before moving on.")
                        .font(.caption2).foregroundStyle(.secondary).padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Loading

    private func load(at t: Double) async {
        guard let clip = model.clip else { loadError = "no clip imported"; return }
        loading = true
        loadError = nil
        let url = clip.url
        do {
            let f = try await Task.detached(priority: .userInitiated) { try await FrameLoader.frame(url: url, time: t) }.value
            frame = f
            if model.rimFrameTime == nil { model.rimFrameTime = f.pts }
        } catch {
            loadError = "frame at \(String(format: "%.2f", t)) s: \(error)"
        }
        loading = false
    }
}
