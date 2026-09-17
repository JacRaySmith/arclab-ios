import ShotGeometry
import SwiftUI

/// Top-down view of the ring (45.7 cm inside diameter) with the ball's centre drawn where the
/// fitted parabola crossed rim height. Front rim (the shooter's side) is at the bottom.
///
/// The dashed inner circle is the swish zone: centres inside it clear the ring by geometry alone,
/// radius (rim − ball) / 2. There are no target bands — the map is descriptive.
struct RimMapView: View {
    /// The crossing class in words. `DepthClass.center` is an identifier, not something to show
    /// (`docs/IMPROVEMENTS-2026-09-16.md` §1.1 item 5).
    static func crossingName(_ c: DepthClass) -> String {
        switch c {
        case .front: return "front of the ring"
        case .center: return "middle of the ring"
        case .back: return "back of the ring"
        }
    }

    let depthPastFrontRim: Double?      // metres past the front rim, 0 … 0.4572
    let depthUnavailableReason: String?
    let depthClass: DepthClass?
    let lateral: Double?                // metres, + right; nil when this camera angle cannot see it
    let viewClass: ViewClass
    let ballDiameter: Double

    private var rimRadius: Double { Court.rimInnerDiameter / 2 }
    private var swishRadius: Double { (Court.rimInnerDiameter - ballDiameter) / 2 }

    private var lateralReason: String {
        switch viewClass {
        case .side: return "not measured from this camera angle (side view sees front/back only)"
        case .oblique: return "not measured: lateral deviation needs the diameter-depth path (not built yet)"
        case .frontal: return "not measured: this build reads left/right from the shot plane, which a frontal view cannot fix"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Canvas { ctx, size in draw(ctx, size: size) }
                .frame(height: 280)
                .frame(maxWidth: .infinity)

            if let d = depthPastFrontRim {
                LabeledContent("Depth past front rim", value: String(format: "%.1f cm of %.1f cm", d * 100, Court.rimInnerDiameter * 100))
                if let c = depthClass {
                    LabeledContent("Crossing", value: RimMapView.crossingName(c))
                }
            } else {
                unavailable("Depth past front rim", depthUnavailableReason)
            }
            if let l = lateral {
                LabeledContent("Left / right", value: String(format: "%+.1f cm", l * 100))
            } else {
                unavailable("Left / right", lateralReason)
            }
            Text("Ring drawn to scale: 45.7 cm inside. Dashed circle = ball centres that pass without touching the ring (\(String(format: "%.1f", swishRadius * 200)) cm across for a \(String(format: "%.1f", ballDiameter * 100)) cm ball).")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func unavailable(_ label: String, _ reason: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(label, value: "not measured")
            if let reason { Text(reason).font(.caption2).foregroundStyle(.secondary) }
        }
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize) {
        let margin: CGFloat = 34
        let side = min(size.width, size.height) - 2 * margin
        guard side > 20 else { return }
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let mToPt = side / (2 * rimRadius)

        func p(_ lateralM: Double, _ depthM: Double) -> CGPoint {
            // depth 0 = front rim (bottom of the picture), 0.4572 = back rim (top).
            CGPoint(x: c.x + lateralM * mToPt, y: c.y + (rimRadius - depthM) * mToPt)
        }

        // Ring
        let ringRect = CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side)
        ctx.stroke(Path(ellipseIn: ringRect), with: .color(.orange), lineWidth: 3)

        // Swish zone
        let sr = swishRadius * mToPt
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - sr, y: c.y - sr, width: 2 * sr, height: 2 * sr)),
                   with: .color(.secondary), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))

        // Axes
        ctx.stroke(Path { path in
            path.move(to: CGPoint(x: c.x, y: c.y - side / 2 - 8)); path.addLine(to: CGPoint(x: c.x, y: c.y + side / 2 + 8))
        }, with: .color(.secondary.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        ctx.draw(Text("back rim / backboard").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: c.x, y: c.y - side / 2 - 16))
        ctx.draw(Text("front rim").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: c.x, y: c.y + side / 2 + 16))

        guard let depth = depthPastFrontRim else {
            ctx.draw(Text("no crossing measured").font(.caption).foregroundStyle(.secondary), at: c)
            return
        }
        let x = lateral ?? 0
        let hit = p(x, depth)

        // The ball itself, to scale, so "did it fit" is visible rather than asserted.
        let br = (ballDiameter / 2) * mToPt
        ctx.stroke(Path(ellipseIn: CGRect(x: hit.x - br, y: hit.y - br, width: 2 * br, height: 2 * br)),
                   with: .color(.blue.opacity(0.55)), lineWidth: 1.5)
        ctx.dot(hit, radius: 5, color: .blue)

        if lateral == nil {
            // Side view: the dot is only known along the front/back axis. Say so on the picture.
            ctx.stroke(Path { path in
                path.move(to: CGPoint(x: c.x - side / 2, y: hit.y)); path.addLine(to: CGPoint(x: c.x + side / 2, y: hit.y))
            }, with: .color(.blue.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            ctx.draw(Text("front/back only").font(.caption2).foregroundStyle(.blue),
                     at: CGPoint(x: c.x, y: hit.y - 12))
        }
    }
}
