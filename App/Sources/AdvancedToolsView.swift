import PhotosUI
import ShotGeometry
import ShotVideo
import SwiftUI

/// The step-by-step tools that used to be the home screen: import a clip, tell the app how fast time
/// really runs, mark the rim, analyse one shot, read the result, look at the raw Vision tracks.
///
/// Moved here out of `ContentView` (`docs/IMPROVEMENTS-2026-09-16.md` §1.1: six `Start` rows and a
/// nine-line footer made the app read as a settings pane). Nothing was deleted — every step, every
/// field and every honesty footer is the same code it was on the home screen. The logs say the
/// single-shot tools and the probe view were opened **zero** times in two days, which is exactly what
/// "developer tools, kept, but out of the way" should look like.
struct AdvancedToolsView: View {
    var model: AnalysisModel
    var session: SessionModel
    var store: SessionStore

    @State private var selection: PhotosPickerItem?

    var body: some View {
        List {
            importSection
            if model.probe != nil { timingSection }
            if model.clip != nil { rimSection }
            if model.clip != nil { sessionSection }
            if model.clip != nil { shotSection }
            if model.analysis != nil { resultsSection }
            if case .failed(let message) = model.phase {
                Section("Error") { Text(message).foregroundStyle(.red) }
            }
            toolsSection
        }
        .navigationTitle("Step-by-step tools")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { ActivityLog.shared.event("screen", ["name": "advanced.tools"]) }
        .onChange(of: selection) { _, item in
            guard let item else { return }
            session.reset()
            model.importAndProbe(item)
        }
    }

    // MARK: 1 — clip

    private var importSection: some View {
        Section {
            PhotosPicker(selection: $selection, matching: .videos, photoLibrary: .shared()) {
                Label("Import clip", systemImage: "film")
            }
            .disabled(model.isBusy)
            if model.phase == .importing { busyRow("Copying clip…") }
            if model.phase == .probing { busyRow("Decoding every frame to measure the real frame rate…") }
            if let clip = model.clip {
                LabeledContent("File", value: clip.url.lastPathComponent)
                Text(clip.source.rawValue).font(.caption).foregroundStyle(.secondary)
            }
            if let p = model.probe {
                LabeledContent("Frame", value: "\(p.width) × \(p.height) px")
                LabeledContent("Measured", value: p.measuredFrameRate > 0 ? String(format: "%.2f fps in the file", p.measuredFrameRate) : "not measured")
                LabeledContent("Length", value: String(format: "%.1f s of file time", model.fileDuration))
            }
        } header: {
            Text("1 · Clip")
        } footer: {
            Text("Slo-mo clips are imported as the original high-frame-rate file when the photo library allows it. Everything runs on-device.")
        }
    }


    // MARK: 2 — timing and lens

    private var timingSection: some View {
        Section {
            Toggle("This clip is slow motion", isOn: Binding(get: { model.isSloMo }, set: { model.setSloMo($0) }))
            LabeledContent("Slow-motion factor") {
                HStack {
                    TextField("factor", value: Binding(get: { model.timeScale }, set: { model.timeScale = max(0.1, $0) }),
                              format: .number.precision(.fractionLength(0...2)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                    Text("×").foregroundStyle(.secondary)
                }
            }
            LabeledContent("Real frame rate", value: model.realFrameRate.map { String(format: "%.1f fps", $0) } ?? "not measured")
            LabeledContent("Horizontal field of view") {
                HStack {
                    TextField("hFOV", value: Binding(get: { model.hfovDegrees }, set: { model.hfovDegrees = max(10, min(140, $0)) }),
                              format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                    Text("°").foregroundStyle(.secondary)
                }
            }
            if model.sloMoSuspected && !model.isSloMo {
                Label("This file measures ≈30 fps with no edit-list stretch — exactly what a slo-mo export with rewritten timestamps looks like. If it was filmed in slo-mo, turn the switch on.",
                      systemImage: "questionmark.circle").font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("2 · Timing and lens")
        } footer: {
            Text("""
                 File time ÷ factor = real time. A 120 fps clip exported with 30 fps timestamps plays 4× slow, and the file cannot say so — the edit stretch reads 1.00×, so the factor is the user's to set. Get it wrong and g_fit comes back ≈4× or ¼ of 9.81, which is exactly what the gravity check is for. 1080p120 slo-mo on this phone is ≈48° horizontal field of view; the field of view sets the scale of every distance.
                 """)
        }
    }

    // MARK: 3 — rim

    private var rimSection: some View {
        Section {
            NavigationLink {
                RimMarkingView(model: model)
            } label: {
                Label("Mark the rim", systemImage: "circle.dashed")
            }
            if let cal = model.calibration {
                LabeledContent("Camera → rim", value: String(format: "%.2f m", cal.distanceToRim))
                LabeledContent("Axis ratio", value: String(format: "%.3f", cal.ellipse.axisRatio))
                if !cal.warnings.isEmpty {
                    Label("\(cal.warnings.count) warning\(cal.warnings.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else if let err = model.calibrationError {
                Text(err).font(.caption).foregroundStyle(.red)
            } else {
                Text(model.rimPoints.isEmpty ? "not marked" : "\(model.rimPoints.count) points marked, not calibrated")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("3 · Rim")
        } footer: {
            Text("The rim's image ellipse is the only scale reference in the shot: 45.72 cm across, 3.048 m up. Mark it once per camera position.")
        }
    }

    // MARK: 4 — session

    private var sessionSection: some View {
        Section {
            NavigationLink {
                SessionView(model: model, session: session, store: store)
            } label: {
                Label("Find and analyze every shot", systemImage: "list.number")
            }
            .disabled(model.calibration == nil)
            if session.scanning {
                busyRow(session.scanMessage ?? "scanning the clip…")
            } else if !session.shots.isEmpty {
                let s = session.summary
                LabeledContent("Shots", value: "\(s.windows) found, \(s.tracked) measured, \(s.accepted) counted")
                LabeledContent("Release speed", value: s.releaseSpeed.map { $0.text(unit: "m/s", decimals: 2) } ?? "not measured")
                LabeledContent("Entry angle", value: s.entryAngleDegrees.map { $0.text(unit: "°", decimals: 1) } ?? "not measured")
            }
            if session.analysing { busyRow("analysing the found shots…") }
        } header: {
            Text("4 · Session")
        } footer: {
            Text(model.calibration == nil
                 ? "Calibrate the rim first: the scan measures arrivals against the rim centre."
                 : "One pass over the clip finds every ball that arrives at the rim, then each window is analysed with the same pipeline as a single shot. Save it at the end of that screen so it counts towards a finding.")
        }
    }

    // MARK: 5 — one shot

    private var shotSection: some View {
        Section {
            NavigationLink {
                ShotPickerView(model: model)
            } label: {
                Label("Pick a shot and analyze", systemImage: "scope")
            }
            .disabled(model.calibration == nil)
            LabeledContent("Window", value: String(format: "%.2f → %.2f s file · %.2f s real",
                                                   model.windowStart, model.windowEnd, model.windowLength / max(model.timeScale, 0.001)))
            if model.analysisBusy { busyRow(model.analysisStage ?? "analysing…") }
            if let err = model.analysisError { Text(err).font(.caption).foregroundStyle(.red) }
        } header: {
            Text("5 · One shot")
        } footer: {
            Text(model.calibration == nil ? "Calibrate the rim first." : "Start the window just before the ball leaves the hand.")
        }
    }

    private var resultsSection: some View {
        Section("6 · Result") {
            NavigationLink {
                SingleShotResultsView(model: model)
            } label: {
                Label("Arc, numbers and rim map", systemImage: "chart.line.uptrend.xyaxis")
            }
            if let a = model.analysis {
                LabeledContent("g_fit", value: String(format: "%.2f m/s² · %@", a.confidence.gFit, GravityNames.verdict(a.confidence.gravityVerdict)))
                LabeledContent("Release angle", value: a.metrics.release.map { String(format: "%.1f°", $0.angleDegrees) } ?? "not measured")
                LabeledContent("Entry angle", value: a.metrics.entryAngleDegrees.map { String(format: "%.1f°", $0) } ?? "not measured")
            }
        }
    }

    private var toolsSection: some View {
        Section("Tools") {
            NavigationLink {
                ProbeTrackView(model: model)
            } label: {
                Label("Probe & Vision tracks", systemImage: "waveform.badge.magnifyingglass")
            }
            .disabled(model.clip == nil)
            NavigationLink {
                ARFormCaptureView()
            } label: {
                Label("AR body capture (experiment)", systemImage: "figure.basketball")
            }
        }
    }

    private func busyRow(_ text: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(text).font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// The gravity check in words. `GravityVerdict.lowConfidence` is an identifier, not a sentence, and
/// it was being shown as one (`docs/IMPROVEMENTS-2026-09-16.md` §1.1 item 5).
enum GravityNames {
    static func verdict(_ v: GravityVerdict) -> String {
        switch v {
        case .accept: return "gravity checks out"
        case .lowConfidence: return "gravity off — low confidence"
        case .reject: return "gravity wrong — rejected"
        }
    }
}
