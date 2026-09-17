import ShotGeometry
import SwiftUI

// ================================================================================================
// MARK: - A verdict in two words
// ================================================================================================

/// The two-word verdict, as a capsule. Nothing is thrown away by shortening it: every chip is drawn
/// next to something that reveals `full`, and no screen may draw one without that tap.
struct VerdictChip: View {
    let wording: VerdictWording
    var body: some View {
        HStack(spacing: 4) {
            if wording.counted { Circle().fill(wording.colour).frame(width: 6, height: 6) }
            Text(wording.text).font(.caption2.bold())
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(wording.colour.opacity(0.18), in: Capsule())
        .foregroundStyle(wording.colour)
    }
}

/// What a shot's status is called in two words, the colour it is drawn in, and the whole sentence it
/// was shortened from. The sentence is the measurement's own wording — this only picks the label.
struct VerdictWording: Equatable {
    var text: String
    var colour: Color
    /// The full reason, exactly as the analyzer or the block rule worded it. Nil only for a queued window.
    var full: String?
    /// True for a shot the block rule counted: the chip then gets its dot.
    var counted: Bool

    static func of(_ shot: SessionShot) -> VerdictWording {
        switch shot.status {
        case .queued:
            return VerdictWording(text: "queued", colour: .secondary, full: nil, counted: false)
        case .analyzing(let s):
            return VerdictWording(text: "working", colour: .blue, full: s, counted: false)
        case .failed(let reason):
            return of(reason: reason)
        case .measured:
            return of(shot.verdict ?? .rejected("this window produced no verdict"))
        }
    }

    static func of(_ verdict: ShotAcceptance.Verdict) -> VerdictWording {
        switch verdict {
        case .accepted:
            return VerdictWording(text: "counted", colour: .green,
                                  full: "This shot passed the block rule and is counted in the session's statistics.",
                                  counted: true)
        case .lowConfidence(let r), .rejected(let r):
            return of(reason: r)
        }
    }

    /// Two words for one of the measured reasons. Each branch matches wording the measurement itself
    /// writes (`ShotAcceptance.evaluate`, `GravityGate.explain`, `ShotRunError`), so a new reason falls
    /// through to "not counted" rather than being mislabelled.
    static func of(reason: String) -> VerdictWording {
        let r = reason.lowercased()
        let colour: Color = .orange
        if SessionModel.isDecodingInterruption(reason) {
            return VerdictWording(text: "paused", colour: .orange, full: reason, counted: false)
        }
        if r.contains("put-back or tip") || r.contains("tip, not a shot") {
            return VerdictWording(text: "tip-in", colour: .orange, full: reason, counted: false)
        }
        if r.contains("g_fit") {
            return VerdictWording(text: "gravity off", colour: .red, full: reason, counted: false)
        }
        if r.contains("detections in this window") || r.contains("no ball was found") || r.contains("no ball-sized track") {
            return VerdictWording(text: "too few points", colour: colour, full: reason, counted: false)
        }
        if r.contains("misses the tracked ball") {
            return VerdictWording(text: "unstable", colour: colour, full: reason, counted: false)
        }
        if r.contains("release height") { return VerdictWording(text: "odd height", colour: colour, full: reason, counted: false) }
        if r.contains("release speed") { return VerdictWording(text: "odd speed", colour: colour, full: reason, counted: false) }
        if r.contains("past the front rim, outside") { return VerdictWording(text: "odd crossing", colour: colour, full: reason, counted: false) }
        if r.contains("window is empty") { return VerdictWording(text: "empty window", colour: colour, full: reason, counted: false) }
        return VerdictWording(text: "not counted", colour: colour, full: reason, counted: false)
    }
}

// ================================================================================================
// MARK: - Depth, as a chip
// ================================================================================================

/// Short / band / long against `SessionCoach.makeDepthBand` — where NBA three-point make probability
/// peaks (grade A). It is where the crossing was, not a target the shooter is scored against.
struct DepthChip: View {
    let depth: Double?

    var body: some View {
        if let d = depth {
            let (text, colour) = Self.label(d)
            Text(text)
                .font(.caption2.bold())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(colour.opacity(0.18), in: Capsule())
                .foregroundStyle(colour)
        } else {
            Text("no crossing").font(.caption2).foregroundStyle(.secondary)
        }
    }

    static func label(_ depth: Double) -> (String, Color) {
        let band = SessionCoach.makeDepthBand
        if depth < band.lowerBound { return (String(format: "%.0f cm short", (band.lowerBound - depth) * 100), .blue) }
        if depth > band.upperBound { return (String(format: "%.0f cm long", (depth - band.upperBound) * 100), .orange) }
        return ("in the band", .green)
    }
}

// ================================================================================================
// MARK: - The arc, 40 × 24 pt
// ================================================================================================

/// The tracked ball positions of one shot, drawn small. It is the detections the fit used, in image
/// pixels, scaled to the box — a picture of the flight, never a source of a number.
struct ArcSparkline: View {
    let samples: [ImageSample]
    var size = CGSize(width: 40, height: 24)

    var body: some View {
        Canvas { ctx, box in
            guard samples.count >= 3 else { return }
            let us = samples.map(\.uv.x), vs = samples.map(\.uv.y)
            guard let minU = us.min(), let maxU = us.max(), let minV = vs.min(), let maxV = vs.max(),
                  maxU - minU > 1e-6, maxV - minV > 1e-6 else { return }
            let inset: CGFloat = 2
            let w = box.width - 2 * inset, h = box.height - 2 * inset
            func point(_ s: ImageSample) -> CGPoint {
                CGPoint(x: inset + CGFloat((s.uv.x - minU) / (maxU - minU)) * w,
                        y: inset + CGFloat((s.uv.y - minV) / (maxV - minV)) * h)
            }
            var path = Path()
            for (i, s) in samples.sorted(by: { $0.t < $1.t }).enumerated() {
                let p = point(s)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            ctx.stroke(path, with: .color(.orange), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            if let last = samples.max(by: { $0.t < $1.t }) { ctx.dot(point(last), radius: 1.6, color: .orange) }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }
}

// ================================================================================================
// MARK: - The shooter's own band
// ================================================================================================

/// Mean ± 1 SD of release speed over every accepted shot this shooter has saved **at this spot**.
///
/// Bandwidth feedback — a number only when the rep falls outside the player's own band — is the one
/// motor-learning result that maps onto ArcLab's measure (`docs/research/ui-research-2026-09-16.md`,
/// grade B: it improves movement consistency, which is what the plan scores). Inside the band the row
/// shows a tick; the number is still one tap away, which is the learner-pulled part.
struct SpeedBand: Equatable {
    var mean: Double
    var sd: Double
    var n: Int
    var spot: ShotSpot

    /// The floor below which a "band" would be the noise of a handful of shots.
    static let minimumShots = 10

    func contains(_ speed: Double) -> Bool { abs(speed - mean) <= sd }
    func delta(_ speed: Double) -> String { String(format: "%+.1f m/s", speed - mean) }

    /// Nil — with no substitute — when the shooter has fewer than ten accepted shots saved at the spot.
    static func from(_ stat: BlockStat?, spot: ShotSpot) -> SpeedBand? {
        guard let stat, let sd = stat.sd, stat.n >= minimumShots, sd > 0 else { return nil }
        return SpeedBand(mean: stat.mean, sd: sd, n: stat.n, spot: spot)
    }
}

// ================================================================================================
// MARK: - The feed
// ================================================================================================

/// One row per finished shot, appended as the analysis runs: shot number, the arc, the numbers, the
/// depth chip and the verdict. Newest at the top, so the shooter never scrolls to see the last shot.
struct ShotFeedView: View {
    let shots: [SessionShot]
    /// Nil when the shooter has no band yet at this spot: every number is then shown.
    let band: SpeedBand?
    @Binding var showEveryNumber: Bool
    @State private var expanded: Set<Int> = []

    /// Finished windows, newest first.
    private var finished: [SessionShot] {
        shots.filter { shot in
            switch shot.status {
            case .measured, .failed: return true
            default: return false
            }
        }
        .sorted { ($0.completionOrder ?? $0.id) > ($1.completionOrder ?? $1.id) }
    }

    var body: some View {
        if finished.isEmpty {
            Text("No shot has finished yet. Each one appears here as it is measured.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            if band != nil {
                Toggle("Show every number", isOn: $showEveryNumber)
                    .font(.caption)
                    .onChange(of: showEveryNumber) { _, on in
                        ActivityLog.shared.event("feed.bandwidth", ["showEveryNumber": on, "n": band?.n, "spot": band?.spot.rawValue])
                    }
            }
            ForEach(finished) { shot in
                row(shot)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if expanded.contains(shot.id) { expanded.remove(shot.id) } else { expanded.insert(shot.id) }
                    }
            }
            if let band {
                Text(String(format: "A tick means the shot was inside your own band at %@: %.2f ± %.2f m/s over %d accepted saved shots. Tap a row for its numbers.",
                            band.spot.rawValue, band.mean, band.sd, band.n))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func row(_ shot: SessionShot) -> some View {
        let wording = VerdictWording.of(shot)
        let isOpen = expanded.contains(shot.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("\(shot.id)")
                    .font(.caption.monospaced().bold()).foregroundStyle(.secondary)
                    .frame(width: 22, alignment: .trailing)
                ArcSparkline(samples: shot.result?.samples ?? [])
                speedView(shot)
                if let angle = shot.row?.releaseAngleDegrees {
                    Text(String(format: "%.0f°", angle)).font(.caption.monospaced())
                }
                Spacer(minLength: 4)
                if shot.row?.verdict.isAccepted == true { DepthChip(depth: shot.row?.depthPastFrontRim) }
                VerdictChip(wording: wording)
            }
            if isOpen {
                if let row = shot.row {
                    Text(String(format: "speed %@ · release %@ · entry %@ · depth %@ · g %.2f",
                                row.releaseSpeed.map { String(format: "%.2f m/s", $0) } ?? "not measured",
                                row.releaseAngleDegrees.map { String(format: "%.0f°", $0) } ?? "not measured",
                                row.entryAngleDegrees.map { String(format: "%.1f°", $0) } ?? "not measured",
                                row.depthPastFrontRim.map { String(format: "%.0f cm", $0 * 100) } ?? "no crossing",
                                row.gFit))
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                if let full = wording.full {
                    Text(full).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 1)
    }

    /// The bandwidth rule, and the one place it is applied.
    @ViewBuilder private func speedView(_ shot: SessionShot) -> some View {
        if let speed = shot.row?.releaseSpeed {
            if let band, !showEveryNumber, shot.row?.verdict.isAccepted == true, band.contains(speed) {
                Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.green)
                    .accessibilityLabel("inside your band")
            } else if let band, !showEveryNumber, shot.row?.verdict.isAccepted == true {
                Text(String(format: "%.2f", speed)).font(.caption.monospaced())
                Text(band.delta(speed)).font(.caption2.monospaced().bold())
                    .foregroundStyle(speed > band.mean ? .orange : .blue)
            } else {
                Text(String(format: "%.2f m/s", speed)).font(.caption.monospaced())
            }
        } else {
            Text("—").font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }

    /// Inside / outside / no band, for the log. Counted over the accepted shots that have a speed.
    static func bandwidthCounts(shots: [SessionShot], band: SpeedBand?) -> (inside: Int, outside: Int, withSpeed: Int) {
        let speeds = shots.compactMap { $0.row?.verdict.isAccepted == true ? $0.row?.releaseSpeed : nil }
        guard let band else { return (0, 0, speeds.count) }
        let inside = speeds.filter { band.contains($0) }.count
        return (inside, speeds.count - inside, speeds.count)
    }
}
