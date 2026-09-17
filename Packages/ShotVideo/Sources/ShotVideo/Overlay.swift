import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CoreText
import ShotGeometry

/// Draws detections, the rim fit, and (optionally) the analysed shot onto a frame. Image coords: origin top-left.
public enum Overlay {
    public struct Item { public var uv: SIMD2<Double>; public var radius: Double; public var rgb: (Double, Double, Double); public var filled: Bool; public var label: String?
        public init(uv: SIMD2<Double>, radius: Double, rgb: (Double, Double, Double), filled: Bool = false, label: String? = nil) { self.uv = uv; self.radius = radius; self.rgb = rgb; self.filled = filled; self.label = label } }

    public static func draw(framePNG: URL, to out: URL, items: [Item], polylines: [([SIMD2<Double>], (Double, Double, Double), Double)], legend: [String]) throws {
        guard let src = CGImageSourceCreateWithURL(framePNG as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw VideoReaderError.noVideoTrack }
        let W = img.width, H = img.height
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
        ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)      // top-left origin
        for (pts, c, w) in polylines where pts.count > 1 {
            ctx.setStrokeColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 0.95)); ctx.setLineWidth(w)
            ctx.beginPath(); ctx.move(to: CGPoint(x: pts[0].x, y: pts[0].y)); for p in pts.dropFirst() { ctx.addLine(to: CGPoint(x: p.x, y: p.y)) }; ctx.strokePath()
        }
        for it in items {
            let r = CGRect(x: it.uv.x - it.radius, y: it.uv.y - it.radius, width: 2 * it.radius, height: 2 * it.radius)
            if it.filled { ctx.setFillColor(CGColor(red: it.rgb.0, green: it.rgb.1, blue: it.rgb.2, alpha: 0.9)); ctx.fillEllipse(in: r) }
            else { ctx.setStrokeColor(CGColor(red: it.rgb.0, green: it.rgb.1, blue: it.rgb.2, alpha: 0.95)); ctx.setLineWidth(2.5); ctx.strokeEllipse(in: r) }
        }
        // legend box
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.6)); ctx.fill(CGRect(x: 10, y: 10, width: 640, height: CGFloat(22 * legend.count + 14)))
        ctx.scaleBy(x: 1, y: -1); ctx.translateBy(x: 0, y: -CGFloat(H))
        for (i, line) in legend.enumerated() {
            let attrs: [CFString: Any] = [kCTFontAttributeName: CTFontCreateWithName("Menlo" as CFString, 16, nil), kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 1)]
            let str = CFAttributedStringCreate(nil, line as CFString, attrs as CFDictionary)!
            let ln = CTLineCreateWithAttributedString(str)
            ctx.textPosition = CGPoint(x: 18, y: CGFloat(H) - CGFloat(30 + 22 * i))
            CTLineDraw(ln, ctx)
        }
        guard let result = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw VideoReaderError.noVideoTrack }
        CGImageDestinationAddImage(dest, result, nil); CGImageDestinationFinalize(dest)
    }
}
