import CoreGraphics
import SwiftUI
import UIKit

/// Maps between image pixel coordinates (top-left origin — what Vision reports, what
/// `CameraIntrinsics` consumes, what the rim points are stored in) and the rectangle the frame
/// occupies inside a view drawn with `.aspectRatio(contentMode: .fit)`.
struct ImageFit {
    let imageSize: CGSize
    let viewSize: CGSize

    var scale: CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        return min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
    }
    var origin: CGPoint {
        CGPoint(x: (viewSize.width - imageSize.width * scale) / 2,
                y: (viewSize.height - imageSize.height * scale) / 2)
    }
    var rect: CGRect { CGRect(origin: origin, size: CGSize(width: imageSize.width * scale, height: imageSize.height * scale)) }

    /// pixel → view point
    func point(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale) }
    func point(_ p: SIMD2<Double>) -> CGPoint { point(CGPoint(x: p.x, y: p.y)) }

    /// view point → pixel
    func pixel(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - origin.x) / scale, y: (p.y - origin.y) / scale) }

    func contains(pixel p: CGPoint) -> Bool {
        p.x >= 0 && p.y >= 0 && p.x <= imageSize.width && p.y <= imageSize.height
    }
}

extension GraphicsContext {
    func dot(_ p: CGPoint, radius: CGFloat, color: Color) {
        fill(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: 2 * radius, height: 2 * radius)), with: .color(color))
    }
    func ring(_ p: CGPoint, radius: CGFloat, color: Color, lineWidth: CGFloat = 1.5) {
        stroke(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: 2 * radius, height: 2 * radius)),
               with: .color(color), lineWidth: lineWidth)
    }
}

/// A zoomed crop around one pixel, so a tapped rim point can be checked against the ring itself.
struct Loupe: View {
    let frame: FrameImage
    let pixel: CGPoint
    var zoom: CGFloat = 6
    var side: CGFloat = 132

    var body: some View {
        let half = side / (2 * zoom)
        let cropRect = CGRect(x: pixel.x - half, y: pixel.y - half, width: 2 * half, height: 2 * half)
        Canvas { ctx, size in
            if let cg = frame.image.cgImage,
               let sub = cg.cropping(to: cropRect.integral.intersection(CGRect(origin: .zero, size: frame.pixelSize))) {
                // Draw the crop so that `pixel` lands in the middle of the loupe.
                let o = cropRect.integral.origin
                let dx = (pixel.x - o.x) * zoom, dy = (pixel.y - o.y) * zoom
                let rect = CGRect(x: size.width / 2 - dx, y: size.height / 2 - dy,
                                  width: CGFloat(sub.width) * zoom, height: CGFloat(sub.height) * zoom)
                ctx.draw(Image(decorative: sub, scale: 1), in: rect)
            }
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            ctx.stroke(Path { p in
                p.move(to: CGPoint(x: c.x - 10, y: c.y)); p.addLine(to: CGPoint(x: c.x + 10, y: c.y))
                p.move(to: CGPoint(x: c.x, y: c.y - 10)); p.addLine(to: CGPoint(x: c.x, y: c.y + 10))
            }, with: .color(.yellow), lineWidth: 1)
            ctx.ring(c, radius: 3, color: .yellow, lineWidth: 1)
        }
        .frame(width: side, height: side)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary, lineWidth: 1))
    }
}
