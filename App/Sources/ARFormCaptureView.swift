import ARKit
import SwiftUI
import UIKit

/// The ARKit body-tracking experiment screen (`docs/research/arkit-body-tracking-spike-2026-09-15.md`).
/// Shows the rear camera with the tracked skeleton drawn over it, a live readout of what ARKit reports,
/// and a Record button that files every frame under Documents/ArcLab/arbody/. Landscape, like the
/// recorder, so the shooter, the arc and the floor fit; this screen cannot run at the same time as the
/// 240 fps `CaptureView` session — ARKit owns the camera while it is up.
struct ARFormCaptureView: View {
    @State private var controller = ARFormCaptureController()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch controller.status {
            case .unsupported(let reason):
                message(title: "AR body tracking is not available here", text: reason, symbol: "figure.walk.motion")
            case .failed(let reason):
                message(title: "The AR session failed", text: reason, symbol: "exclamationmark.triangle")
            default:
                if controller.cameraPermission == .denied || controller.cameraPermission == .restricted {
                    message(title: "ArcLab cannot use the camera",
                            text: "Camera access is off for ArcLab. Open Settings → Privacy & Security → Camera and switch Camera on, then come back.",
                            symbol: "lock.shield", settings: true)
                } else {
                    cameraScreen
                }
            }
        }
        .statusBarHidden()
        .preferredColorScheme(.dark)
        .navigationBarBackButtonHidden(true)
        .task {
            ActivityLog.shared.event("screen", ["name": "arbody"])
            await controller.begin()
        }
        .onAppear { CaptureView.requestLandscape(true) }
        .onDisappear {
            controller.end()
            CaptureView.requestLandscape(false)
        }
    }

    // MARK: - Camera + skeleton + readout

    private var cameraScreen: some View {
        ZStack {
            if let view = controller.arView {
                ARSceneContainer(view: view).ignoresSafeArea()
            } else {
                ProgressView().tint(.white)
            }
            SkeletonOverlay(joints: controller.overlayJoints, bones: controller.overlayBones)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack {
                HStack(alignment: .top) {
                    readout
                    Spacer(minLength: 12)
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.headline).padding(10).background(.black.opacity(0.5), in: Circle())
                    }
                    .foregroundStyle(.white)
                }
                Spacer()
                HStack(alignment: .bottom) {
                    Toggle("× scale", isOn: $controller.drawScaled)
                        .toggleStyle(.button).tint(.orange).font(.caption)
                    Spacer()
                    recordButton
                    Spacer()
                    if let r = controller.lastResult {
                        Text(r).font(.caption2).foregroundStyle(.white).frame(maxWidth: 220, alignment: .trailing)
                    }
                }
            }
            .padding(16)
        }
    }

    private var readout: some View {
        let c = controller
        return VStack(alignment: .leading, spacing: 3) {
            row("Status", c.status == .starting ? "starting…" : c.status == .recording ? "RECORDING" : "running")
            row("Format", c.videoFormatDescription)
            row("Body", c.bodyDetected ? (c.anchorIsTracked ? "yes, tracked" : "yes, not tracked") : "no")
            row("Joints", "\(c.trackedJointCount) / \(c.jointCount) tracked")
            row("Scale", c.scaleFactor.map { String(format: "%.3f", $0) } ?? "—")
            row("Anchor upd/s", String(format: "%.0f", c.anchorUpdatesPerSecond))
            row("Frames/s", String(format: "%.1f", c.framesPerSecond))
            row("First body", c.firstBodySeenAfter.map { String(format: "%.1f s after start", $0) } ?? String(format: "none after %.0f s", c.secondsSinceStart))
            if c.status == .recording {
                row("Recorded", String(format: "%d frames, %d with body, %.1f s", c.recordedFrames, c.recordedDetected, c.recordingSeconds))
            }
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(spacing: 8) {
            Text(k).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
            Text(v)
        }
    }

    private var recordButton: some View {
        Button {
            controller.toggleRecording()
        } label: {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 72, height: 72)
                if controller.status == .recording {
                    RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 30, height: 30)
                } else {
                    Circle().fill(.red).frame(width: 58, height: 58)
                }
            }
        }
        .disabled(controller.status != .running && controller.status != .recording)
        .accessibilityLabel(controller.status == .recording ? "Stop recording" : "Record")
    }

    private func message(title: String, text: String, symbol: String, settings: Bool = false) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.largeTitle)
            Text(title).font(.headline)
            Text(text).font(.callout).multilineTextAlignment(.center)
            if settings {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(.borderedProminent)
            }
            Button("Back") { dismiss() }
        }
        .foregroundStyle(.white)
        .padding(32)
        .frame(maxWidth: 520)
    }
}

// MARK: - ARSCNView host

/// Hosts the controller's `ARSCNView`; the session is run and paused by the controller, not here.
private struct ARSceneContainer: UIViewRepresentable {
    let view: ARSCNView
    func makeUIView(context: Context) -> ARSCNView { view }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

// MARK: - Skeleton overlay

/// Projected joints as dots (filled = `isJointTracked`, hollow = rig position only) and bones to the
/// parent joint (orange when both ends are tracked, grey otherwise). Coordinates are view points from
/// `ARCamera.projectPoint(_:orientation:viewportSize:)` for the view's own size.
private struct SkeletonOverlay: View {
    let joints: [ARFormCaptureController.OverlayJoint]
    let bones: [ARFormCaptureController.OverlayBone]

    var body: some View {
        Canvas { ctx, _ in
            for b in bones {
                var p = Path()
                p.move(to: b.a); p.addLine(to: b.b)
                ctx.stroke(p, with: .color(b.tracked ? .orange : .gray.opacity(0.6)), lineWidth: b.tracked ? 2.5 : 1)
            }
            for j in joints {
                let rect = CGRect(x: j.point.x - 4, y: j.point.y - 4, width: 8, height: 8)
                if j.tracked {
                    ctx.fill(Path(ellipseIn: rect), with: .color(.yellow))
                } else {
                    ctx.stroke(Path(ellipseIn: rect), with: .color(.gray), lineWidth: 1)
                }
            }
        }
    }
}
