import AVFoundation
import SwiftUI
import UIKit

/// The recording screen: film the block here instead of in Camera.app.
///
/// The point of it is that the shooter never chooses a slo-mo setting, a lens, a zoom or a focus mode,
/// and the analysis never has to be *told* the time base or the field of view — both are read off the
/// format that produced the file and written into a sidecar next to the movie (`RecordedClip`).
///
/// Landscape only, because every framing rule in `docs/PHASE0-FILMING-PROTOCOL.md` assumes it and a
/// portrait clip cannot hold the shooter, the arc and the rim at once.
struct CaptureView: View {
    /// Called on the main actor when a clip has been written and its sidecar saved.
    var onRecorded: (RecordedClip) -> Void

    @State private var controller = CaptureController()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch controller.status {
            case .unavailable(let message):
                unavailable(message)
            default:
                if controller.cameraPermission == .denied || controller.cameraPermission == .restricted {
                    permissionDenied
                } else {
                    cameraScreen
                }
            }
        }
        .statusBarHidden()
        .preferredColorScheme(.dark)
        .task {
            controller.onRecorded = { clip in
                ActivityLog.shared.event("capture.recorded", ["file": clip.movieFileName, "requestedFps": clip.requestedFrameRate, "nominalFps": clip.measuredNominalFrameRate,
                                                              "averageFps": clip.measuredAverageFrameRate, "seconds": clip.durationSeconds, "hfov": clip.videoFieldOfViewDegrees])
                onRecorded(clip)
            }
            await controller.begin()
        }
        .onAppear { CaptureView.requestLandscape(true) }
        .onDisappear {
            controller.end()
            CaptureView.requestLandscape(false)
        }
    }

    // MARK: - The camera screen

    private var cameraScreen: some View {
        GeometryReader { geo in
            let video = CaptureView.videoRect(in: geo.size, aspect: aspectRatio)
            ZStack {
                CameraPreview(controller: controller)
                    .ignoresSafeArea()
                    .onTapGesture { location in
                        controller.lockFocusAndExposure(atPreviewPoint: location)
                    }

                FramingOverlay(rect: video)
                    .allowsHitTesting(false)

                VStack {
                    HStack(alignment: .top) {
                        readout
                        Spacer(minLength: 12)
                        elapsedBadge
                    }
                    Spacer()
                    HStack(alignment: .bottom) {
                        warnings
                        Spacer(minLength: 12)
                    }
                }
                .padding(20)

                HStack {
                    Spacer()
                    recordButton
                        .padding(.trailing, 24)
                }
            }
        }
    }

    private var aspectRatio: CGFloat {
        guard let config = controller.configuration, config.height > 0 else { return 16.0 / 9.0 }
        return CGFloat(config.width) / CGFloat(config.height)
    }

    // MARK: - Readout

    private var readout: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(controller.configuration?.line ?? "Setting the camera up…")
                .font(.system(.footnote, design: .monospaced).weight(.semibold))
            Label(controller.lockNote, systemImage: lockIcon)
                .font(.caption2)
                .foregroundStyle(controller.focusLocked && controller.exposureLocked ? Color.green : Color.yellow)
            if let rim = controller.rimInFrame {
                Label(rim ? "Orange in the rim band" : "No orange in the rim band — re-aim",
                      systemImage: rim ? "circle.circle.fill" : "circle.circle")
                    .font(.caption2)
                    .foregroundStyle(rim ? Color.green : Color.orange)
            }
            Text("1× wide lens, no zoom. Tap the shooter to lock focus there.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private var lockIcon: String {
        controller.focusLocked && controller.exposureLocked ? "lock.fill" : "lock.open"
    }

    private var elapsedBadge: some View {
        Group {
            if controller.isRecording || controller.elapsed > 0 {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 10, height: 10)
                    Text(CaptureView.timeString(controller.elapsed))
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .monospacedDigit()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.black.opacity(0.45), in: Capsule())
            }
        }
    }

    @ViewBuilder private var warnings: some View {
        VStack(alignment: .leading, spacing: 6) {
            if case .failed(let message) = controller.status {
                warningChip(message, colour: .red)
            }
            if let thermal = controller.thermalWarning {
                warningChip(thermal, colour: .orange)
            }
            if controller.microphonePermission == .denied {
                warningChip("No microphone access: your spoken make/miss log will not be recorded.", colour: .orange)
            }
            ForEach(controller.configuration?.warnings ?? [], id: \.self) { warning in
                warningChip(warning, colour: .orange)
            }
            if let clip = controller.lastClip {
                warningChip("Saved: \(clip.summaryLine)"
                            + (clip.durationSeconds.map { String(format: " · %.1f s", $0) } ?? ""),
                            colour: .green)
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
    }

    private func warningChip(_ text: String, colour: Color) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(colour.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(colour.opacity(0.8), lineWidth: 1))
    }

    // MARK: - Record button

    private var recordButton: some View {
        Button {
            if controller.isRecording { controller.stopRecording() } else { controller.startRecording() }
        } label: {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 78, height: 78)
                if controller.isRecording {
                    RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 32, height: 32)
                } else {
                    Circle().fill(.red).frame(width: 62, height: 62)
                }
            }
        }
        .disabled(!controller.canRecord && !controller.isRecording)
        .opacity(controller.canRecord || controller.isRecording ? 1 : 0.4)
        .accessibilityLabel(controller.isRecording ? "Stop recording" : "Start recording")
    }

    // MARK: - Degraded states

    private func unavailable(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "video.slash").font(.largeTitle)
            Text("No camera here").font(.headline)
            Text(message).font(.callout).multilineTextAlignment(.center)
            Button("Back") { dismiss() }.buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
        .padding(32)
        .frame(maxWidth: 520)
    }

    private var permissionDenied: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield").font(.largeTitle)
            Text("ArcLab cannot use the camera").font(.headline)
            Text("Camera access is off for ArcLab. Open Settings → Privacy & Security → Camera (or ArcLab's own page) and switch Camera on, then come back to this screen.")
                .font(.callout).multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            Button("Back") { dismiss() }
        }
        .foregroundStyle(.white)
        .padding(32)
        .frame(maxWidth: 520)
    }

    // MARK: - Helpers

    static func timeString(_ seconds: TimeInterval) -> String {
        let total = max(0, seconds)
        let minutes = Int(total) / 60
        let secs = Int(total) % 60
        let tenths = Int((total - floor(total)) * 10)
        return String(format: "%d:%02d.%d", minutes, secs, tenths)
    }

    /// Where the preview's picture actually is inside the view. The preview layer uses `.resizeAspect`,
    /// so the overlay must be drawn against the letterboxed video rectangle and not the whole screen —
    /// otherwise the "feet on this line" guide would point at something that is not in the file.
    static func videoRect(in size: CGSize, aspect: CGFloat) -> CGRect {
        guard size.width > 0, size.height > 0, aspect > 0 else { return .zero }
        let viewAspect = size.width / size.height
        if viewAspect > aspect {
            let width = size.height * aspect
            return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
        } else {
            let height = size.width / aspect
            return CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
        }
    }

    /// Landscape only while this screen is up, then back to whatever the app allows.
    static func requestLandscape(_ landscape: Bool) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        let mask: UIInterfaceOrientationMask = landscape ? [.landscapeLeft, .landscapeRight] : .all
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    }
}

// MARK: - Framing overlay

/// The framing rules from `docs/PHASE0-FILMING-PROTOCOL.md` §"The 10-line version", drawn on the preview
/// so nobody has to remember them: feet at the bottom edge, rim in the top third, ~1 m of air above the
/// highest arc. Drawn inside the video rectangle, so what it promises is what the file will hold.
struct FramingOverlay: View {
    var rect: CGRect

    /// Top of the rim band, as a fraction of frame height. The protocol says "rim in the top third".
    private let rimBandTop: CGFloat = 0.08
    private let rimBandBottom: CGFloat = 0.33
    /// Where the shooter's feet should sit: near the bottom edge, with a little floor showing.
    private let feetLine: CGFloat = 0.88

    var body: some View {
        ZStack(alignment: .topLeading) {
            let bandTop = rect.minY + rect.height * rimBandTop
            let bandHeight = rect.height * (rimBandBottom - rimBandTop)

            // Rim band
            Rectangle()
                .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                .foregroundStyle(.orange.opacity(0.9))
                .frame(width: rect.width, height: bandHeight)
                .background(Color.orange.opacity(0.06))
                .offset(x: rect.minX, y: bandTop)

            Text("rim inside this band")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.black.opacity(0.45), in: Capsule())
                .offset(x: rect.minX + 10, y: bandTop + bandHeight - 20)

            // Sky reminder, above the rim band
            Text("keep about a metre of sky above the highest arc")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.black.opacity(0.45), in: Capsule())
                .offset(x: rect.minX + 10, y: rect.minY + 8)

            // Feet line
            Rectangle()
                .fill(.green.opacity(0.9))
                .frame(width: rect.width, height: 2)
                .offset(x: rect.minX, y: rect.minY + rect.height * feetLine)

            Text("feet on this line")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.black.opacity(0.45), in: Capsule())
                .offset(x: rect.minX + 10, y: rect.minY + rect.height * feetLine + 6)

            // The edge of what is actually recorded.
            Rectangle()
                .stroke(.white.opacity(0.25), lineWidth: 1)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Preview layer

/// `AVCaptureVideoPreviewLayer` as its view's backing layer — no sublayer to keep in sync on rotation.
final class CameraPreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct CameraPreview: UIViewRepresentable {
    var controller: CaptureController

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.backgroundColor = .black
        // `.resizeAspect`, never `.resizeAspectFill`: the shooter must see exactly the frame that will be
        // written, or the framing guides are a lie about what the analysis will get.
        view.previewLayer.videoGravity = .resizeAspect
        view.previewLayer.session = controller.session
        controller.attach(previewLayer: view.previewLayer)
        return view
    }

    func updateUIView(_ view: CameraPreviewUIView, context: Context) {
        if view.previewLayer.session !== controller.session {
            view.previewLayer.session = controller.session
            controller.attach(previewLayer: view.previewLayer)
        }
    }
}
