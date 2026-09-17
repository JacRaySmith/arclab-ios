import SwiftUI

/// A strip chart of one measurement in shot order: one mark per shot, a line through the mean, and a
/// band one standard deviation wide. Accepted shots are filled; shots the block rule excluded are
/// hollow and greyed, so a reader can see both the series and what was left out of it.
///
/// There is no target band and no "good" region: the axis is the data's own range, and the only
/// reference line is this block's own mean.
struct ShotStripChartView: View {
    struct Point: Identifiable {
        var id: Int            // shot number
        var value: Double?
        var accepted: Bool
    }

    let title: String
    let unit: String
    let decimals: Int
    let points: [Point]
    /// Statistics of the accepted shots only, drawn as the mean line and ±1 SD band.
    let stat: BlockStat?
    let unavailableReason: String

    private var values: [Double] { points.compactMap(\.value) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(stat.map { $0.text(unit: unit, decimals: decimals) } ?? "not measured")
                    .font(stat == nil ? .caption.italic() : .caption.monospaced())
                    .foregroundStyle(stat == nil ? .secondary : .primary)
            }
            if values.isEmpty {
                Text(unavailableReason).font(.caption2).foregroundStyle(.secondary)
            } else {
                Canvas { ctx, size in draw(ctx, size: size) }
                    .frame(height: 74)
                let missing = points.filter { $0.value == nil }.count
                HStack {
                    Text(String(format: "%.\(decimals)f–%.\(decimals)f \(unit) over %d shot\(points.count == 1 ? "" : "s")",
                                values.min() ?? 0, values.max() ?? 0, points.count))
                    Spacer()
                    if missing > 0 { Text("\(missing) not measured") }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize) {
        guard !values.isEmpty, points.count > 0 else { return }
        let lo = values.min()!, hi = values.max()!
        let pad = max((hi - lo) * 0.15, max(abs(hi), 1) * 0.01)
        let low = lo - pad, high = hi + pad
        let inset: CGFloat = 8
        func y(_ v: Double) -> CGFloat {
            let f = (v - low) / max(high - low, 1e-9)
            return size.height - inset - CGFloat(f) * (size.height - 2 * inset)
        }
        func x(_ i: Int) -> CGFloat {
            guard points.count > 1 else { return size.width / 2 }
            return inset + CGFloat(i) / CGFloat(points.count - 1) * (size.width - 2 * inset)
        }

        if let stat {
            if let sd = stat.sd {
                let top = y(stat.mean + sd), bottom = y(stat.mean - sd)
                ctx.fill(Path(CGRect(x: 0, y: min(top, bottom), width: size.width, height: abs(bottom - top))),
                         with: .color(.blue.opacity(0.10)))
            }
            let ym = y(stat.mean)
            ctx.stroke(Path { p in p.move(to: CGPoint(x: 0, y: ym)); p.addLine(to: CGPoint(x: size.width, y: ym)) },
                       with: .color(.blue.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }

        // The series line through the shots that have a value, in shot order.
        var path = Path()
        var started = false
        for (i, p) in points.enumerated() {
            guard let v = p.value else { started = false; continue }
            let pt = CGPoint(x: x(i), y: y(v))
            if started { path.addLine(to: pt) } else { path.move(to: pt); started = true }
        }
        ctx.stroke(path, with: .color(.secondary.opacity(0.45)), lineWidth: 1)

        for (i, p) in points.enumerated() {
            guard let v = p.value else { continue }
            let pt = CGPoint(x: x(i), y: y(v))
            if p.accepted { ctx.dot(pt, radius: 3.5, color: .blue) }
            else { ctx.ring(pt, radius: 3.5, color: .secondary, lineWidth: 1) }
        }
    }
}
