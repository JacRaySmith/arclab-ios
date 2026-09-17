import ShotGeometry
import SwiftUI

/// The block's rim map: the ring to scale, one dot per **accepted** shot where the fitted parabola
/// crossed rim height, coloured by the inferred outcome.
///
/// Side views measure front/back only, so those dots sit on the centre line and the picture says so
/// rather than implying a left/right the camera could not see. The dashed circle is the swish zone,
/// radius (rim − ball)/2. There are no target bands: the map is descriptive.
struct SessionRimMapView: View {
    let rows: [BlockRow]
    let ballDiameter: Double

    private var rimRadius: Double { Court.rimInnerDiameter / 2 }
    private var swishRadius: Double { (Court.rimInnerDiameter - ballDiameter) / 2 }

    private var accepted: [BlockRow] { rows.filter { $0.verdict.isAccepted && $0.depthPastFrontRim != nil } }
    private var sideOnly: Bool { accepted.contains { $0.lateralDeviation == nil } }
    private var withoutDepth: Int { rows.filter { $0.verdict.isAccepted && $0.depthPastFrontRim == nil }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Canvas { ctx, size in draw(ctx, size: size) }
                .frame(height: 300)
                .frame(maxWidth: .infinity)

            HStack(spacing: 14) {
                legend(.green, "make")
                legend(.red, "miss")
                legend(.secondary, "unknown")
            }
            .font(.caption2)

            if accepted.isEmpty {
                Text("not measured: no accepted shot produced a rim crossing yet")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                let depths = accepted.compactMap(\.depthPastFrontRim)
                if let stat = Stats.summarize(depths.map { $0 * 100 }) {
                    LabeledContent("Depth past front rim", value: stat.text(unit: "cm"))
                }
                if sideOnly {
                    Text("Left / right: not measured from this camera angle (a side view sees front/back only), so every dot is drawn on the centre line.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if withoutDepth > 0 {
                    Text("\(withoutDepth) accepted shot\(withoutDepth == 1 ? "" : "s") produced no crossing and \(withoutDepth == 1 ? "is" : "are") not drawn.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text("Ring drawn to scale: 45.7 cm inside. Dashed circle = ball centres that pass without touching the ring (\(String(format: "%.1f", swishRadius * 200)) cm across for a \(String(format: "%.1f", ballDiameter * 100)) cm ball). Outcomes are inferred from the ball at the rim, never from a scorer.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private func color(_ o: InferredOutcome) -> Color {
        switch o {
        case .make: return .green
        case .miss: return .red
        case .unknown: return .secondary
        }
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize) {
        let margin: CGFloat = 34
        let side = min(size.width, size.height) - 2 * margin
        guard side > 20 else { return }
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let mToPt = side / (2 * rimRadius)

        func p(_ lateralM: Double, _ depthM: Double) -> CGPoint {
            CGPoint(x: c.x + lateralM * mToPt, y: c.y + (rimRadius - depthM) * mToPt)
        }

        let ringRect = CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side)
        ctx.stroke(Path(ellipseIn: ringRect), with: .color(.orange), lineWidth: 3)

        let sr = swishRadius * mToPt
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - sr, y: c.y - sr, width: 2 * sr, height: 2 * sr)),
                   with: .color(.secondary), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))

        ctx.stroke(Path { path in
            path.move(to: CGPoint(x: c.x, y: c.y - side / 2 - 8)); path.addLine(to: CGPoint(x: c.x, y: c.y + side / 2 + 8))
        }, with: .color(.secondary.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        ctx.draw(Text("back rim / backboard").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: c.x, y: c.y - side / 2 - 16))
        ctx.draw(Text("front rim").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: c.x, y: c.y + side / 2 + 16))

        let drawn = accepted
        guard !drawn.isEmpty else {
            ctx.draw(Text("no accepted crossing yet").font(.caption).foregroundStyle(.secondary), at: c)
            return
        }
        // Side views know only the front/back coordinate: spread the dots along a short jitter-free
        // ladder across the centre line so overlapping shots stay countable, and label the axis.
        let br = (ballDiameter / 2) * mToPt
        for (i, row) in drawn.enumerated() {
            guard let depth = row.depthPastFrontRim else { continue }
            let lateralKnown = row.lateralDeviation
            let offsetPt: CGFloat = lateralKnown == nil ? CGFloat((i % 5) - 2) * (br * 0.5) : 0
            let hit = CGPoint(x: p(lateralKnown ?? 0, depth).x + offsetPt, y: p(lateralKnown ?? 0, depth).y)
            let colour = color(row.outcome.outcome)
            if lateralKnown == nil {
                ctx.stroke(Path { path in
                    path.move(to: CGPoint(x: c.x - side / 2, y: hit.y)); path.addLine(to: CGPoint(x: c.x + side / 2, y: hit.y))
                }, with: .color(colour.opacity(0.18)), lineWidth: 1)
            }
            ctx.ring(hit, radius: br, color: colour.opacity(0.4), lineWidth: 1)
            ctx.dot(hit, radius: 4, color: colour)
        }
        if sideOnly {
            ctx.draw(Text("front/back only").font(.caption2).foregroundStyle(.secondary),
                     at: CGPoint(x: c.x, y: c.y + side / 2 + 2))
        }
    }
}
