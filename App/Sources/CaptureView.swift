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
    @Environment(\.scenePhase) private var scenePhase

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
        .onAppear {
            ActivityLog.shared.event("screen", ["name": "capture"])
            // The spoken feedback owns the shared `AVAudioSession` as `.playback` while it talks, and
            // this session takes it as `.playAndRecord` because it records the shooter's "make"/"miss".
            // Two clients fighting over it is one of the documented ways a capture session is
            // interrupted (`audioDeviceInUseByAnotherClient`) — and nothing it could say over a
            // recording is worth hearing anyway.
            ShotSpeaker.shared.silence()
            CaptureView.requestLandscape(true)
            #if DEBUG
            let failures = CaptureView.geometrySelfCheck()
            ActivityLog.shared.event("capture.geometry.selfcheck",
                                     ["failures": failures.count, "detail": failures.joined(separator: " | ")])
            #endif
        }
        // `requestGeometryUpdate` is refused while the scene is not foreground-active, and `.onAppear`
        // fires exactly once. Asking again when the scene becomes active is what stops the screen from
        // being stuck in portrait for the whole recording after a permission sheet or a phone call.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { CaptureView.requestLandscape(true) }
        }
        // The session coming up is the other moment the request is worth repeating: on a cold start it
        // is several hundred milliseconds after `.onAppear`.
        .onChange(of: controller.configuration != nil) { _, configured in
            if configured { CaptureView.requestLandscape(true) }
        }
        .onDisappear {
            ActivityLog.shared.event("screen", ["name": "capture.left"])
            controller.end()
            CaptureView.requestLandscape(false)
        }
    }

    // MARK: - The camera screen

    /// The preview and the overlay share one coordinate space: both ignore the safe area, so both are
    /// the full screen, and the overlay is placed at `controller.previewVideoRect` — the rectangle the
    /// preview layer itself reports for the picture. The chrome (readout, warnings, record button)
    /// stays inside the safe area, where a notch or a home indicator cannot sit on top of it.
    ///
    /// This used to be a `GeometryReader` over the *safe-area* size with the *sensor's* aspect ratio
    /// assumed. Both halves were wrong the moment the phone was turned: in landscape the safe-area
    /// insets are large and one-sided (59 pt on the notch edge, 0 on the other), so the overlay was
    /// both smaller than the picture and off-centre; and while the interface was still portrait the
    /// preview showed the frame turned upright — 9:16, not 16:9 — so the overlay kept drawing a wide
    /// short band across a tall picture. Neither can happen now: nothing here assumes an aspect ratio
    /// or a coordinate space, it asks the layer.
    private var cameraScreen: some View {
        ZStack {
            CameraPreview(controller: controller)
                .ignoresSafeArea()
                .onTapGesture { location in
                    controller.lockFocusAndExposure(atPreviewPoint: location)
                }

            if controller.previewVideoRect.width > 1, controller.previewVideoRect.height > 1 {
                FramingOverlay(rect: controller.previewVideoRect)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

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
            // A black preview is never left unexplained: if iOS took the camera away or the session
            // hit a runtime error, the reason is on screen.
            if let health = controller.healthNote {
                warningChip(health, colour: controller.isInterrupted ? .orange : .red)
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

    /// The same aspect fit, but told the *source* dimensions and how far the preview has been rotated,
    /// so it swaps them when the picture has been turned upright. The sensor's frame is always
    /// landscape (1920 × 1080); at 90° or 270° the preview shows it as 1080 × 1920 and the fitted
    /// rectangle is tall, not wide. Forgetting that is what drew a landscape overlay over a portrait
    /// picture during the whole portrait → landscape transition.
    ///
    /// Only used as the fallback for `CaptureController.refreshPreviewRect`: the preview layer is
    /// asked first. Kept pure (no AVFoundation, no UIKit state) so it can be checked on its own.
    static func videoRect(in size: CGSize, sourceWidth: Int, sourceHeight: Int, rotationDegrees: CGFloat) -> CGRect {
        guard sourceWidth > 0, sourceHeight > 0 else { return .zero }
        let quarterTurned = abs(rotationDegrees.truncatingRemainder(dividingBy: 180) - 90) < 1
        let w = CGFloat(quarterTurned ? sourceHeight : sourceWidth)
        let h = CGFloat(quarterTurned ? sourceWidth : sourceHeight)
        return videoRect(in: size, aspect: w / h)
    }

    /// Landscape only while this screen is up, then back to whatever the app allows.
    ///
    /// The old version guarded on a foreground-active scene and then threw the result away, so a
    /// refused request — a rotation the system would not perform — was indistinguishable from one that
    /// worked, and the screen silently stayed portrait. `requestGeometryUpdate`'s error handler is the
    /// only thing that says which happened, so it is logged.
    static func requestLandscape(_ landscape: Bool) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            ActivityLog.shared.event("capture.orientation", ["landscape": landscape, "asked": false,
                                                             "why": "no window scene"])
            return
        }
        let mask: UIInterfaceOrientationMask = landscape ? [.landscapeLeft, .landscapeRight] : .all
        let wasLandscape = scene.effectiveGeometry.interfaceOrientation.isLandscape
        let active = scene.activationState == .foregroundActive
        ActivityLog.shared.event("capture.orientation", ["landscape": landscape, "asked": true,
                                                         "wasLandscape": wasLandscape, "foregroundActive": active])
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            // Called only when the request fails. Nothing capturing the scene: this closure is not
            // main-actor isolated and `ActivityLog` is the only thing it needs.
            ActivityLog.shared.event("capture.orientation.refused",
                                     ["landscape": landscape, "wasLandscape": wasLandscape,
                                      "foregroundActive": active, "error": error.localizedDescription])
        }
    }

    #if DEBUG
    /// A unit-style check of the pure rectangle arithmetic, run once when the record screen opens and
    /// written to the activity log. There is no test target for the app, so this is where a wrong
    /// number would be caught: an empty list is the pass.
    static func geometrySelfCheck() -> [String] {
        var failures: [String] = []
        func near(_ a: CGFloat, _ b: CGFloat, _ what: String, tolerance: CGFloat = 0.5) {
            if abs(a - b) > tolerance { failures.append("\(what): \(a) ≠ \(b)") }
        }
        // Landscape screen, landscape picture: letterboxed left and right, full height.
        let landscape = videoRect(in: CGSize(width: 852, height: 393), sourceWidth: 1920, sourceHeight: 1080,
                                  rotationDegrees: 0)
        near(landscape.height, 393, "landscape height")
        near(landscape.width, 393 * 16 / 9, "landscape width")
        near(landscape.minX, (852 - 393 * 16 / 9) / 2, "landscape x")
        near(landscape.minY, 0, "landscape y")
        // 180° is the other landscape orientation: the same rectangle.
        let flipped = videoRect(in: CGSize(width: 852, height: 393), sourceWidth: 1920, sourceHeight: 1080,
                                rotationDegrees: 180)
        near(flipped.width, landscape.width, "landscapeLeft vs landscapeRight width")
        near(flipped.minX, landscape.minX, "landscapeLeft vs landscapeRight x")
        // Portrait screen with the picture turned upright: full width, letterboxed top and bottom,
        // and *not* the 16:9 band the old code drew.
        let upright = videoRect(in: CGSize(width: 393, height: 852), sourceWidth: 1920, sourceHeight: 1080,
                                rotationDegrees: 90)
        near(upright.width, 393, "upright width")
        near(upright.height, 393 * 16 / 9, "upright height")
        near(upright.minY, (852 - 393 * 16 / 9) / 2, "upright y")
        if upright.height < upright.width { failures.append("upright rect is wider than it is tall") }
        // Mid-transition: a landscape screen still showing the upright picture is a narrow tall strip.
        let transition = videoRect(in: CGSize(width: 852, height: 393), sourceWidth: 1920, sourceHeight: 1080,
                                   rotationDegrees: 270)
        near(transition.height, 393, "transition height")
        near(transition.width, 393 * 9 / 16, "transition width")
        // Degenerate inputs must not produce a rectangle at all.
        if !videoRect(in: .zero, sourceWidth: 1920, sourceHeight: 1080, rotationDegrees: 0).isEmpty {
            failures.append("a zero-sized view produced a non-empty rect")
        }
        if !videoRect(in: CGSize(width: 852, height: 393), sourceWidth: 0, sourceHeight: 0, rotationDegrees: 0).isEmpty {
            failures.append("a zero-sized source produced a non-empty rect")
        }
        return failures
    }
    #endif
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

    /// Called on every layout pass — which is every rotation, every safe-area change and every time
    /// this view is resized. It is what tells SwiftUI that the picture has moved: a `GeometryReader`
    /// around the overlay measured the *safe area*, not this view, and so never agreed with it.
    var onLayout: (@MainActor () -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        // The preview layer is this view's own backing layer, so there is no sublayer frame to keep in
        // step — only the reported rectangle, which changes with the bounds.
        onLayout?()
    }
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
        view.onLayout = { [weak controller] in controller?.previewGeometryChanged() }
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
