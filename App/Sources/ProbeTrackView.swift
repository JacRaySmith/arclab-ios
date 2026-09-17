import ShotVideo
import SwiftUI

/// The original diagnostic screen: what the file really is, and every Vision trajectory in the
/// first 10 s of the decoded timeline. Kept reachable — it is how a clip that will not analyse
/// gets debugged (wrong frame rate, dropped frames, rotated transform, no tracks at all).
struct ProbeTrackView: View {
    var model: AnalysisModel

    var body: some View {
        List {
            if let probe = model.probe { probeSection(probe) } else {
                Text("Import a clip first.").foregroundStyle(.secondary)
            }
            if model.probe != nil { trackingSection }
            if let run = model.run { tracksSection(run) }
            if case .failed(let message) = model.phase {
                Section("Error") { Text(message).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Probe & tracks")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func probeSection(_ p: VideoProbeResult) -> some View {
        Section("Probe (measured from decoded frames)") {
            row("Size", "\(p.width) × \(p.height) px")
            row("Codec", p.codec)
            row("Decoded frames", "\(p.decodedFrames)")
            row("Measured frame rate", p.decodedFrames >= 2 && p.measuredFrameRate > 0
                ? String(format: "%.2f fps", p.measuredFrameRate) : "not measured")
            row("Nominal frame rate (header)", p.nominalFrameRate > 0 ? String(format: "%.2f fps", p.nominalFrameRate) : "not measured")
            row("Edit stretch", String(format: "%.2f×", p.sloMoStretch))
            row("Slow-motion factor in use", String(format: "%.2f×", model.timeScale))
            row("Real frame rate (measured × factor)", model.realFrameRate.map { String(format: "%.1f fps", $0) } ?? "not measured")
            row("Track duration", String(format: "%.3f s", p.trackDuration))
            row("PTS range", p.decodedFrames >= 1 ? String(format: "%.3f → %.3f s", p.firstPTS, p.lastPTS) : "not measured")
            row("Median interval", p.medianFrameInterval > 0 ? String(format: "%.4f s", p.medianFrameInterval) : "not measured")
            row("Interval jitter", p.medianFrameInterval > 0 ? String(format: "%.2f %%", p.intervalJitterPercent) : "not measured")
            row("Dropped-frame gaps", "\(p.droppedFrameGaps)")
            row("Transform", p.transformIsIdentity ? "identity" : "rotated (\(p.preferredTransformDescription))")
            if !p.editSegments.isEmpty {
                DisclosureGroup("Edit segments (\(p.editSegments.count))") {
                    ForEach(Array(p.editSegments.enumerated()), id: \.offset) { _, s in
                        Text(s).font(.caption.monospaced())
                    }
                }
            }
            if p.notes.isEmpty {
                row("Notes", "none")
            } else {
                ForEach(Array(p.notes.enumerated()), id: \.offset) { _, note in
                    Label(note, systemImage: "exclamationmark.triangle").font(.footnote)
                }
            }
        }
    }

    private var trackingSection: some View {
        Section {
            Button {
                model.track()
            } label: {
                Label(String(format: "Find trajectories in first %.0f s", AnalysisModel.trackingWindowSeconds), systemImage: "scope")
            }
            .disabled(model.isBusy)
            if model.phase == .tracking {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(model.progressText ?? "running Vision trajectory detection…").font(.footnote).foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Runs Vision's DetectTrajectoriesRequest over the first \(Int(AnalysisModel.trackingWindowSeconds)) s of the decoded timeline (stretched time for slo-mo files). On-device only.")
        }
    }

    private func tracksSection(_ run: TrajectoryRun) -> some View {
        Section("Trajectories: \(run.tracks.count) found in \(run.framesProcessed) frames") {
            if run.tracks.isEmpty {
                Text("No trajectory was detected in this window.").foregroundStyle(.secondary)
            }
            ForEach(Array(run.tracks.enumerated()), id: \.element.uuid) { i, track in
                VStack(alignment: .leading, spacing: 4) {
                    Text("Track \(i + 1)").font(.headline)
                    Text(String(format: "%.3f → %.3f s  (%.3f s, %d samples)",
                                track.firstPTS, track.lastPTS, track.lastPTS - track.firstPTS, track.samples.count))
                        .font(.caption.monospaced())
                    Text(String(format: "max confidence %.2f · mean radius %.1f px", track.maxConfidence, track.meanRadiusPx))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Use as the shot window") {
                        model.windowStart = max(0, track.firstPTS - 0.35 * model.timeScale)
                        model.windowLength = min(30, max(1, (track.lastPTS - track.firstPTS) + 0.75 * model.timeScale))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value)
    }
}
