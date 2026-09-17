import ShotGeometry
import ShotVideo
import SwiftUI
import UIKit

/// Step 2: scrub to just before one shot, set the window, analyse it.
struct ShotPickerView: View {
    @Bindable var model: AnalysisModel

    @State private var frame: FrameImage?
    @State private var loading = false
    @State private var loadError: String?
    @State private var showResults = false

    private var duration: Double { max(model.fileDuration, 0.001) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                framePreview
                windowControls
                analyseBlock
                resultSummary
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .navigationTitle("Pick a shot")
        .navigationBarTitleDisplayMode(.inline)
        .task { if frame == nil { await load(at: model.windowStart) } }
        .navigationDestination(isPresented: $showResults) { SingleShotResultsView(model: model) }
    }

    // MARK: Preview

    @ViewBuilder private var framePreview: some View {
        ZStack {
            if let frame {
                GeometryReader { geo in
                    let fit = ImageFit(imageSize: frame.pixelSize, viewSize: geo.size)
                    ZStack {
                        Image(uiImage: frame.image).resizable().aspectRatio(contentMode: .fit)
                        Canvas { ctx, _ in
                            for p in model.rimPoints { ctx.dot(fit.point(p), radius: 3, color: .green) }
                        }
                    }
                }
                .aspectRatio(frame.pixelSize.width / max(frame.pixelSize.height, 1), contentMode: .fit)
            } else {
                Rectangle().fill(.quaternary).aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay { loading ? AnyView(ProgressView()) : AnyView(Text("no frame").foregroundStyle(.secondary)) }
            }
        }
        if let loadError { Text(loadError).font(.footnote).foregroundStyle(.red) }
    }

    // MARK: Window

    private var windowControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Window start").font(.subheadline)
                Spacer()
                Text(String(format: "%.2f → %.2f s file time", model.windowStart, min(model.windowEnd, duration)))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Slider(value: $model.windowStart, in: 0...max(duration - 0.1, 0.1)) { editing in
                if !editing { Task { await load(at: model.windowStart) } }
            }
            HStack {
                Button("−0.5 s") { model.windowStart = max(0, model.windowStart - 0.5); Task { await load(at: model.windowStart) } }
                Button("+0.5 s") { model.windowStart = min(duration, model.windowStart + 0.5); Task { await load(at: model.windowStart) } }
                Spacer()
                Button { Task { await load(at: model.windowStart) } } label: {
                    if loading { ProgressView().controlSize(.small) } else { Text("Show this frame") }
                }
                .disabled(loading)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Stepper(value: $model.windowLength, in: 1...30, step: 0.5) {
                HStack {
                    Text("Window length")
                    Spacer()
                    Text(String(format: "%.1f s file · %.2f s real", model.windowLength, model.windowLength / max(model.timeScale, 0.001)))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            Text("Start just before the ball leaves the hand. The window is *file* time: at a \(String(format: "%.0f", model.timeScale))× slow-motion factor, \(String(format: "%.1f", model.windowLength)) s of file is \(String(format: "%.2f", model.windowLength / max(model.timeScale, 0.001))) s of real flight.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Analyse

    @ViewBuilder private var analyseBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.calibration == nil {
                Label("Mark and calibrate the rim first — every metric is scaled by it.", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
            Button {
                model.analyseWindow()
            } label: {
                Label("Analyze this window", systemImage: "function").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canAnalyse)

            if model.analysisBusy {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(model.analysisStage ?? "working…").font(.footnote).foregroundStyle(.secondary)
                }
                Text("Vision trajectory pass → background-difference ball detector → shot-plane solve and parabola fit. All on-device; nothing is uploaded.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let err = model.analysisError {
                GroupBox("The analyzer could not measure this window") {
                    Text(err).font(.footnote.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder private var resultSummary: some View {
        if let a = model.analysis {
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("g_fit", value: String(format: "%.2f m/s² (%@)", a.confidence.gFit, GravityNames.verdict(a.confidence.gravityVerdict)))
                    LabeledContent("Ball samples used", value: "\(a.confidence.nDetections) of \(model.analysisSamples.count) (\(a.confidence.nInliers) inliers)")
                    Button {
                        showResults = true
                    } label: {
                        Label("See the arc and the rim map", systemImage: "chart.line.uptrend.xyaxis").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
                }
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
            frame = try await Task.detached(priority: .userInitiated) { try await FrameLoader.frame(url: url, time: t) }.value
        } catch {
            loadError = "frame at \(String(format: "%.2f", t)) s: \(error)"
        }
        loading = false
    }
}
