import Charts
import SwiftUI

/// Progress charts: one chart per metric, saved sessions from one spot on the x axis in date order,
/// the session's mean on the y axis with a ±1 SD band and its n written on every point.
///
/// Nothing here is a target. The only references drawn are published measurements (skilled shooters'
/// release-speed spread, the depth band where published make rates peak) and ring geometry (32° and
/// 40° entry angles), each labelled as what it is. A chart with fewer than two sessions carrying the
/// metric says so in one line instead of drawing.
struct ProgressChartsView: View {
    @Bindable var store: SessionStore
    let spot: ShotSpot
    @State private var compareSpots = false

    /// One session's value of one metric.
    struct Point: Identifiable {
        var id: UUID
        var date: Date
        var clip: String
        var spot: ShotSpot
        var value: Double
        var sd: Double?
        var n: Int
    }

    enum Reference {
        case band(lo: Double, hi: Double, label: String)
        case line(Double, label: String)
    }

    struct Metric: Identifiable {
        var id: String { title }
        var title: String
        var unit: String
        var decimals: Int
        /// Whether the ±1 SD band is drawn. Off for values that are themselves a spread or a rate.
        var showsSD: Bool
        var references: [Reference]
        /// What a change of the chart's size would mean, in the app's own units, where a rule defines it.
        var caption: String
        var extract: (BlockSummary) -> (value: Double, sd: Double?, n: Int)?
    }

    /// Per-session summaries, built once per body evaluation: `SavedSession.summary` re-runs the block rule.
    private func summaries(at s: ShotSpot) -> [(SavedSession, BlockSummary)] {
        store.sessions(at: s).sorted { $0.date < $1.date }.map { ($0, $0.summary) }
    }

    private func points(_ m: Metric, at s: ShotSpot, from rows: [(SavedSession, BlockSummary)]) -> [Point] {
        rows.compactMap { session, sum in
            guard let v = m.extract(sum) else { return nil }
            return Point(id: session.id, date: session.date, clip: session.clipName, spot: s, value: v.value, sd: v.sd, n: v.n)
        }
    }

    var body: some View {
        let rows = summaries(at: spot)
        Section {
            if rows.count < 2 {
                Text("Charts start at two saved sessions from this spot; \(rows.count) so far.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Toggle("Compare spots on the spread chart", isOn: $compareSpots)
                    .font(.subheadline)
                ForEach(Self.metrics) { m in
                    let pts = points(m, at: spot, from: rows)
                    if pts.count < 2 {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.title).font(.subheadline)
                            Text("Charts start at two sessions with this measure; \(pts.count) of \(rows.count) saved sessions have it.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        let overlay: [Point] = (m.id == Self.speedSpreadTitle && compareSpots)
                            ? ShotSpot.allCases.filter { $0 != spot }.flatMap { other in
                                points(m, at: other, from: summaries(at: other))
                              }
                            : []
                        MetricChart(metric: m, points: pts, overlay: overlay, primarySpot: spot)
                    }
                }
            }
        } header: {
            Text("\(spot.rawValue) — session by session")
        } footer: {
            Text("Each point is one saved session's mean over its accepted shots, with n written on it and a band one standard deviation wide. Shaded bands and dashed lines are published measurements or ring geometry — references to read against, never targets.")
        }
        .onAppear {
            ActivityLog.shared.event("screen", ["name": "progress.charts", "spot": spot.rawValue, "sessions": rows.count])
        }
    }

    // MARK: Metrics

    static let speedSpreadTitle = "Release-speed spread (SD)"

    private static var skilledBand: Reference {
        .band(lo: SessionCoach.skilledSpeedSdRange.lowerBound, hi: SessionCoach.skilledSpeedSdRange.upperBound,
              label: "measured skilled shooters (Slegers 2021)")
    }

    static let metrics: [Metric] = [
        Metric(title: speedSpreadTitle, unit: "m/s", decimals: 2, showsSD: false,
               references: [skilledBand],
               caption: String(format: "0.1 m/s of speed spread is associated with about %.0f cm of depth spread at the line (geometry). The shaded band is the spread measured in 12 skilled shooters, the same at the free-throw line and the three — a reference, not a target.", SessionCoach.depthCmPerTenthOfAMetrePerSecond),
               extract: { s in s.releaseSpeed.flatMap { v in v.sd.map { (value: $0, sd: nil, n: v.n) } } }),
        Metric(title: "Release speed", unit: "m/s", decimals: 2, showsSD: true,
               references: [],
               caption: String(format: "0.1 m/s of mean speed moves the crossing about %.0f cm at free-throw length (geometry). The app's rules read the spread, not the mean.", SessionCoach.depthCmPerTenthOfAMetrePerSecond),
               extract: { s in s.releaseSpeed.map { (value: $0.mean, sd: $0.sd, n: $0.n) } }),
        Metric(title: "Release angle", unit: "°", decimals: 1, showsSD: true,
               references: [],
               caption: "No rule in this app maps a change in release angle to a distance at the rim; the skilled shooters' release-angle spread (1.2–1.3°) was only a weak correlate of performance.",
               extract: { s in s.releaseAngleDegrees.map { (value: $0.mean, sd: $0.sd, n: $0.n) } }),
        Metric(title: "Entry angle", unit: "°", decimals: 1, showsSD: true,
               references: [.line(32, label: "32°: clean swish impossible below (geometry)"),
                            .line(SessionCoach.flatArcMean, label: "40°: under 3 cm margin below (geometry)")],
               caption: "Below 40° the ball's margin through the ring is under 3 cm; below 32° a clean swish is geometrically impossible. Published make rates peak in the mid-40s, and make probability is flatter in entry angle than in depth.",
               extract: { s in s.entryAngleDegrees.map { (value: $0.mean, sd: $0.sd, n: $0.n) } }),
        Metric(title: "Crossing depth past front rim", unit: "cm", decimals: 1, showsSD: true,
               references: [.band(lo: SessionCoach.makeDepthBand.lowerBound * 100, hi: SessionCoach.makeDepthBand.upperBound * 100,
                                  label: String(format: "%.0f–%.0f cm: published make-rate peak", SessionCoach.makeDepthBand.lowerBound * 100, SessionCoach.makeDepthBand.upperBound * 100))],
               caption: String(format: "The %.0f–%.0f cm band is where published NBA 3-point make probability peaks (Daly-Grafstein & Bornn); the ring centre is 23 cm. A session's band here is its depth spread, which is what the speed spread maps to.", SessionCoach.makeDepthBand.lowerBound * 100, SessionCoach.makeDepthBand.upperBound * 100),
               extract: { s in s.depthPastFrontRim.map { (value: $0.mean * 100, sd: $0.sd.map { $0 * 100 }, n: $0.n) } }),
        Metric(title: "Inferred make rate", unit: "%", decimals: 0, showsSD: false,
               references: [],
               caption: "Makes ÷ (makes + misses), inferred from where the ball went after the rim, not from a scorer. Shots with an unknown outcome are left out of the denominator, so n here can be below the accepted count.",
               extract: { s in
                   let n = s.makes + s.misses
                   guard n > 0 else { return nil }
                   return (value: 100 * Double(s.makes) / Double(n), sd: nil, n: n)
               }),
        Metric(title: "Rhythm time (lowest wrist → release)", unit: "ms", decimals: 0, showsSD: true,
               references: [],
               caption: "From the pose track, or the body model where a session has only that. No rule in this app maps a change in rhythm time to a distance at the rim.",
               extract: { s in
                   if let p = s.dipToReleaseSeconds { return (value: p.mean * 1000, sd: p.sd.map { $0 * 1000 }, n: p.n) }
                   return s.bodyDipToReleaseMilliseconds.map { (value: $0.mean, sd: $0.sd, n: $0.n) }
               }),
        Metric(title: "Jump height", unit: "cm", decimals: 1, showsSD: true,
               references: [],
               caption: "Body model, metres from the shooter's own pixel height. No rule in this app maps jump height to a distance at the rim.",
               extract: { s in s.jumpHeightMetres.map { (value: $0.mean * 100, sd: $0.sd.map { $0 * 100 }, n: $0.n) } }),
        Metric(title: "Head stability", unit: "× height", decimals: 3, showsSD: true,
               references: [],
               caption: "Body model, head movement through the shot as a fraction of the shooter's height. No rule in this app maps it to a distance at the rim.",
               extract: { s in s.headStabilityNormalised.map { (value: $0.mean, sd: $0.sd, n: $0.n) } }),
    ]
}

// MARK: - One chart

private struct MetricChart: View {
    let metric: ProgressChartsView.Metric
    let points: [ProgressChartsView.Point]
    /// Other spots, drawn only on the spread chart when "compare spots" is on.
    let overlay: [ProgressChartsView.Point]
    let primarySpot: ShotSpot
    @State private var selectedDate: Date?

    private var all: [ProgressChartsView.Point] { points + overlay }

    private var selected: ProgressChartsView.Point? {
        guard let d = selectedDate else { return nil }
        return all.min { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) }
    }

    private var yDomain: ClosedRange<Double> {
        var lo = Double.infinity, hi = -Double.infinity
        for p in all {
            let s = metric.showsSD ? (p.sd ?? 0) : 0
            lo = min(lo, p.value - s); hi = max(hi, p.value + s)
        }
        for r in metric.references {
            switch r {
            case .band(let a, let b, _): lo = min(lo, a); hi = max(hi, b)
            case .line(let v, _): lo = min(lo, v); hi = max(hi, v)
            }
        }
        guard lo.isFinite, hi.isFinite else { return 0...1 }
        let pad = max((hi - lo) * 0.15, max(abs(hi), 1) * 0.02)
        return (lo - pad)...(hi + pad)
    }

    private func fmt(_ v: Double) -> String { String(format: "%.\(metric.decimals)f", v) }

    private var summaryText: String {
        guard let first = points.first, let last = points.last else { return "" }
        return "\(fmt(first.value)) \(metric.unit) (n \(first.n)) in the first session to \(fmt(last.value)) \(metric.unit) (n \(last.n)) in the latest, over \(points.count) sessions"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(metric.title).font(.subheadline)
                Spacer()
                Text("\(points.count) sessions").font(.caption).foregroundStyle(.secondary)
            }
            chart
                .frame(height: 170)
                .accessibilityLabel("\(metric.title) at \(primarySpot.rawValue): \(summaryText)")
            if let p = selected {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(p.date, format: .dateTime.day().month().year().hour().minute())\(overlay.isEmpty ? "" : " · \(p.spot.rawValue)")")
                        .font(.caption.bold())
                    Text("\(p.clip) · n \(p.n) · \(fmt(p.value))\(p.sd.map { " ± \(fmt($0))" } ?? "") \(metric.unit)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("Tap a point for the session's date, clip, n and value.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Text(metric.caption).font(.caption2).foregroundStyle(.secondary)
            if !overlay.isEmpty {
                Text("Comparing spots: skilled shooters' speed spread was the same at the free-throw line and the three, so spread that widens with distance is the thing to look at.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chart: some View {
        Chart {
            ForEach(Array(metric.references.enumerated()), id: \.offset) { _, r in
                switch r {
                case .band(let lo, let hi, let label):
                    RectangleMark(yStart: .value("Reference low", lo), yEnd: .value("Reference high", hi))
                        .foregroundStyle(Color.secondary.opacity(0.12))
                        .annotation(position: .overlay, alignment: .topLeading) {
                            Text(label).font(.caption2).foregroundStyle(.secondary).padding(2)
                        }
                case .line(let v, let label):
                    RuleMark(y: .value("Reference", v))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text(label).font(.caption2).foregroundStyle(.secondary)
                        }
                }
            }
            ForEach(all) { p in
                if metric.showsSD, let sd = p.sd {
                    AreaMark(x: .value("Session", p.date),
                             yStart: .value("Mean − SD", p.value - sd),
                             yEnd: .value("Mean + SD", p.value + sd),
                             series: .value("Spot", p.spot.rawValue))
                        .foregroundStyle(by: .value("Spot", p.spot.rawValue))
                        .opacity(0.12)
                }
                LineMark(x: .value("Session", p.date), y: .value(metric.title, p.value),
                         series: .value("Spot", p.spot.rawValue))
                    .foregroundStyle(by: .value("Spot", p.spot.rawValue))
                    .opacity(p.spot == primarySpot ? 0.6 : 0.35)
                PointMark(x: .value("Session", p.date), y: .value(metric.title, p.value))
                    .foregroundStyle(by: .value("Spot", p.spot.rawValue))
                    .symbolSize(p.spot == primarySpot ? 50 : 30)
                    .annotation(position: .top, spacing: 2) {
                        Text("n \(p.n)").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            if let p = selected {
                RuleMark(x: .value("Selected", p.date))
                    .foregroundStyle(Color.secondary.opacity(0.4))
            }
        }
        .chartYScale(domain: yDomain)
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.day().month()) } }
        .chartYAxisLabel(metric.unit, position: .trailing, alignment: .center)
        .chartLegend(overlay.isEmpty ? .hidden : .visible)
        .chartXSelection(value: $selectedDate)
    }
}
