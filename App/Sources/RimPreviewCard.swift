import ShotGeometry
import SwiftUI

/// The rim proposal, drawn on the frame it was found on, inline in the guided flow.
///
/// It is the same picture `RimMarkingView` draws — the fitted ellipse from `RimCalibration.ellipse`
/// and its centre, in decoded-image pixels through `ImageFit` — without the tapping. A shooter can
/// see whether the ring is the ring; "camera 9.7 m from the ring, ellipse ratio 0.28" could not tell
/// them that. Nothing here changes the calibration: it only shows it.
struct RimPreviewCard: View {
    let clipURL: URL
    let frameTime: Double
    let calibration: RimCalibration
    var height: CGFloat = 200

    @State private var frame: FrameImage?
    @State private var loadError: String?

    var body: some View {
        ZStack {
            if let frame {
                GeometryReader { geo in
                    let fit = ImageFit(imageSize: frame.pixelSize, viewSize: geo.size)
                    ZStack {
                        Image(uiImage: frame.image).resizable().aspectRatio(contentMode: .fit)
                        Canvas { ctx, _ in draw(ctx, fit: fit) }
                    }
                }
            } else {
                Rectangle().fill(.quaternary)
                    .overlay {
                        if let loadError {
                            Text(loadError).font(.caption2).foregroundStyle(.secondary).padding()
                        } else {
                            ProgressView()
                        }
                    }
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: frameTime) { await load() }
    }

    private func draw(_ ctx: GraphicsContext, fit: ImageFit) {
        var path = Path()
        for i in 0...180 {
            let phi = Double(i) / 180 * 2 * .pi
            let p = fit.point(calibration.ellipse.point(at: phi))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        ctx.stroke(path, with: .color(.cyan), lineWidth: 2)
        ctx.ring(fit.point(calibration.ellipse.center), radius: 4, color: .cyan)
    }

    private func load() async {
        guard frame == nil else { return }
        do {
            frame = try await FrameLoader.frame(url: clipURL, time: frameTime)
            loadError = nil
        } catch {
            loadError = "The frame at \(String(format: "%.1f", frameTime)) s could not be decoded, so the ring cannot be drawn here. The marking screen can still load another frame."
        }
    }
}
