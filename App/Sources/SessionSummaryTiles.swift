import ShotGeometry
import SwiftUI

/// The evidence grade of a comparison, as a small capsule. The grade is on the *published number*
/// the band comes from, never on this shooter's measurement.
struct EvidenceChip: View {
    let grade: EvidenceGrade
    var body: some View {
        Text(grade.letter)
            .font(.caption2.bold())
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(colour.opacity(0.18), in: Capsule())
            .foregroundStyle(colour)
            .accessibilityLabel("evidence grade \(grade.letter): \(grade.meaning)")
    }
    private var colour: Color {
        switch grade {
        case .a: return .green
        case .b: return .teal
        case .c: return .orange
        case .d: return .secondary
        }
    }
}

/// The three numbers a session is read by, as tiles: release speed (mean and its spread), entry
/// angle, and depth past the front rim. Each carries the band measured shooters sat in, where one
/// exists, with the grade of that band — a description of a population, never a target for this
/// shooter. A measure that could not be computed shows no number and keeps its reason underneath.
struct SessionSummaryTiles: View {
    let summary: BlockSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                speedTile
                angleTile
                depthTile
            }
            ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
                Text(reason).font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The reasons for whichever tiles have no number. Printed in full, never truncated.
    private var reasons: [String] {
        var out: [String] = []
        if summary.releaseSpeed == nil { out.append("Release speed: " + summary.unavailableReason(for: summary.releaseSpeed, geometry: true)) }
        if summary.entryAngleDegrees == nil { out.append("Entry angle: " + summary.unavailableReason(for: summary.entryAngleDegrees, geometry: true)) }
        if summary.depthPastFrontRim == nil { out.append("Depth: " + summary.unavailableReason(for: summary.depthPastFrontRim, geometry: true)) }
        return out
    }

    // MARK: The three tiles

    /// The mean is the shooter's, the band is on the **spread**: release-speed SD is the measure that
    /// tracked three-point performance (Slegers, Lee & Wong 2021; r = −0.96, n = 12), and no published
    /// number says what a mean release speed ought to be — it depends on the distance and the shooter.
    private var speedTile: some View {
        let stat = summary.releaseSpeed
        let sd = stat?.sd
        let band = SessionCoach.skilledSpeedSdRange
        return tile(
            label: "Release speed",
            value: stat.map { String(format: "%.2f", $0.mean) },
            unit: "m/s",
            detail: sd.map { String(format: "± %.2f SD (n %d)", $0, stat?.n ?? 0) } ?? stat.map { _ in "one shot has no spread" },
            bandText: String(format: "skilled spread %.2f–%.2f", band.lowerBound, band.upperBound),
            state: sd.map { band.contains($0) ? .inBand : ($0 > band.upperBound ? .above : .below) },
            grade: .a)
    }

    private var angleTile: some View {
        let stat = summary.entryAngleDegrees
        let band = SessionCoach.entryAngleMakeBand
        return tile(
            label: "Entry angle",
            value: stat.map { String(format: "%.1f", $0.mean) },
            unit: "°",
            detail: stat.map { s in s.sd.map { String(format: "± %.1f SD (n %d)", $0, s.n) } ?? "n 1" },
            bandText: String(format: "makes peak %.0f–%.0f°", band.lowerBound, band.upperBound),
            state: stat.map { band.contains($0.mean) ? .inBand : ($0.mean > band.upperBound ? .above : .below) },
            grade: .a)
    }

    private var depthTile: some View {
        let stat = summary.depthPastFrontRim
        let band = SessionCoach.makeDepthBand
        return tile(
            label: "Depth past front rim",
            value: stat.map { String(format: "%.0f", $0.mean * 100) },
            unit: "cm",
            detail: stat.map { s in s.sd.map { String(format: "± %.0f SD (n %d)", $0 * 100, s.n) } ?? "n 1" },
            bandText: String(format: "makes peak %.0f–%.0f cm", band.lowerBound * 100, band.upperBound * 100),
            state: stat.map { band.contains($0.mean) ? .inBand : ($0.mean > band.upperBound ? .above : .below) },
            grade: .a)
    }

    private enum BandState { case inBand, above, below }

    private func tile(label: String, value: String?, unit: String, detail: String?,
                      bandText: String, state: BandState?, grade: EvidenceGrade) -> some View {
        let colour: Color = {
            switch state {
            case .inBand: return .green
            case .above, .below: return .orange
            case nil: return .secondary
            }
        }()
        return VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value ?? "—")
                    .font(.title2.monospaced().bold())
                    .foregroundStyle(value == nil ? .secondary : .primary)
                if value != nil { Text(unit).font(.caption2).foregroundStyle(.secondary) }
            }
            .lineLimit(1).minimumScaleFactor(0.6)
            Text(detail ?? "not measured").font(.caption2).foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true).minimumScaleFactor(0.8)
            HStack(spacing: 4) {
                EvidenceChip(grade: grade)
                Text(bandText).font(.caption2).foregroundStyle(colour)
                    .lineLimit(2).minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(colour.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(colour.opacity(0.28), lineWidth: 1))
    }
}
