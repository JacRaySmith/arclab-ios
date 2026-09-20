import PhotosUI
import ShotGeometry
import SwiftUI

/// The vertical jump test: film three jumps, get a height for each, keep the best and the spread.
///
/// The screen is honest about two things throughout. First, this is a phone-video test, not a force
/// plate. Second, the number it reports is a *measurement with an error bar*, and the error bar is
/// on screen next to the number rather than buried.
struct JumpTestView: View {
    @Bindable var store: JumpStore
    @State private var model = JumpModel()
    @State private var showCapture = false
    @State private var picked: PhotosPickerItem?
    @State private var saved = false

    var body: some View {
        List {
            if let err = model.error { Section { Text(err).font(.footnote).foregroundStyle(.red) } }
            protocolSection
            jumpsSection
            if model.attempts.contains(where: \.measured) { resultSection }
            limitsSection
            historySection
        }
        .navigationTitle("Vertical jump")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { ActivityLog.shared.event("screen", ["name": "jump.test", "tests": store.tests.count]) }
        .fullScreenCover(isPresented: $showCapture) {
            CaptureView { recorded in
                showCapture = false
                model.analyse(recorded: recorded)
            }
        }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            picked = nil
            model.analyse(picked: item)
        }
    }

    // MARK: How to film it

    private var protocolSection: some View {
        Section {
            Label("Stand side-on to the camera, with your whole body in the shot — head to feet, with room above your head.", systemImage: "figure.stand")
            Label("Put the phone on something steady. Landscape. Be the only person in the picture.", systemImage: "iphone.gen3")
            Label("Three jumps. Dip down and swing your arms, jump as high as you can, land where you took off.", systemImage: "figure.jumprope")
            Label("Rest about \(JumpModel.restSeconds) seconds between jumps. Tired legs jump lower, and that is not what this is measuring.", systemImage: "timer")
            Label("Start recording while you are standing still, and stop after you have landed. One jump per clip.", systemImage: "record.circle")
                .font(.callout)
        } header: {
            Text("How to film it")
        } footer: {
            Text("ArcLab films at 240 frames a second, which is what makes the timing good enough. A clip from Photos works too, as long as it was filmed in Slo-mo.")
        }
        .font(.callout)
    }

    // MARK: The three jumps

    private var jumpsSection: some View {
        Section {
            ForEach(model.attempts) { attempt in
                NavigationLink {
                    JumpAttemptDetailView(attempt: attempt)
                } label: {
                    JumpAttemptRow(attempt: attempt)
                }
            }
            if model.busy {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(model.stage ?? "Working").font(.footnote).foregroundStyle(.secondary)
                }
            } else if !model.isComplete {
                Button {
                    showCapture = true
                } label: {
                    Label("Record jump \(model.nextJumpNumber)", systemImage: "record.circle")
                }
                PhotosPicker(selection: $picked, matching: .videos, photoLibrary: .shared()) {
                    Label("Use a clip from Photos instead", systemImage: "film")
                }
            }
            if !model.attempts.isEmpty, !model.busy {
                Button(role: .destructive) { model.removeLast() } label: {
                    Label("Undo the last jump", systemImage: "arrow.uturn.backward")
                }
                .font(.footnote)
            }
        } header: {
            Text("Your three jumps")
        } footer: {
            if model.attempts.isEmpty {
                Text("Nothing measured yet. Each jump takes the phone a few seconds to read.")
            } else {
                Text("Tap a jump to see how it was measured and what it is worth.")
            }
        }
    }

    // MARK: The result

    @ViewBuilder private var resultSection: some View {
        let test = model.session
        if let s = test.summary {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(format: "%.1f cm", 100 * s.bestMetres))
                        .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                    Text("Your best of \(s.n) jump\(s.n == 1 ? "" : "s"). That is the number to compare against next time.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                LabeledContent("Average") { Text(String(format: "%.1f cm", 100 * s.meanMetres)).monospacedDigit() }
                LabeledContent("Best minus worst") { Text(String(format: "%.1f cm", 100 * s.spreadMetres)).monospacedDigit() }
                if let sd = s.sdMetres {
                    LabeledContent("Spread (n \(s.n))") { Text(String(format: "± %.1f cm", 100 * sd)).monospacedDigit() }
                } else if let why = s.sdUnavailableReason {
                    Text("No spread: \(why).").font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Measured by") { Text("flight time").foregroundStyle(.secondary) }
                Text(String(format: "Each jump carries about ± %.1f cm. A change smaller than that is not a change.", 100 * s.typicalUncertaintyMetres))
                    .font(.caption).foregroundStyle(.secondary)
                if model.attempts.count > s.n {
                    Text("\(model.attempts.count - s.n) of your \(model.attempts.count) jumps could not be measured. Open them to see why.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if saved {
                    Label("Saved", systemImage: "checkmark.circle.fill").font(.footnote).foregroundStyle(.green)
                } else {
                    Button {
                        store.save(test)
                        model.logTest(test)
                        saved = true
                    } label: {
                        Label("Save this test", systemImage: "square.and.arrow.down")
                    }
                }
                Button {
                    model.reset(); saved = false
                } label: {
                    Label("Start a new test", systemImage: "arrow.clockwise")
                }
                .font(.footnote)
            } header: {
                Text("Result")
            } footer: {
                Text("Height is worked out from how long your feet were off the floor: h = g × t² ÷ 8. Nothing has to be measured on the court for that — only the clock inside the camera.")
            }
        }
    }

    // MARK: What it is and is not

    private var limitsSection: some View {
        Section {
            Text("This is a phone-video test, not a force plate. It measures how long you were in the air and turns that into a height. It is good at telling you whether you are jumping higher than last month; it is not a lab number and should not be compared with one.")
            Text("Flight time reads a little low here, because the app reads take-off a hair late and landing a hair early. Each jump says by how much.")
            Text("How this compares with a force plate or a jump mat has NOT been checked against the research for this app. Until it is, treat the number as ArcLab's own scale: compare it with your own past tests, not with anyone else's.")
                .foregroundStyle(.orange)
            ShooterHeightRow()
        } header: {
            Text("What this can and cannot tell you")
        } footer: {
            Text("Your height is only used for the second, cross-check measurement (how far your hips rose). The main number does not need it.")
        }
        .font(.footnote)
    }

    private var historySection: some View {
        Section {
            NavigationLink { JumpHistoryView(store: store) } label: {
                Label("Past tests", systemImage: "chart.line.uptrend.xyaxis")
            }
            Text(store.trendSentence).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// One line in the list of three jumps. Its own view so the type checker does not have to solve the
/// whole screen at once.
private struct JumpAttemptRow: View {
    let attempt: JumpAttempt

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Jump \(attempt.index)").font(Font.subheadline.weight(.semibold))
                Spacer()
                Text(attempt.headline)
                    .font(attempt.measured ? Font.subheadline.monospacedDigit() : Font.caption)
                    .foregroundStyle(attempt.measured ? Color.primary : Color.orange)
                    .multilineTextAlignment(.trailing)
            }
            if let f = attempt.flightSeconds, let fps = attempt.frameRate {
                Text(String(format: "%.0f ms in the air, measured at %.0f frames a second", 1000 * f, fps))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - One jump, in full

struct JumpAttemptDetailView: View {
    let attempt: JumpAttempt

    var body: some View {
        List {
            Section("Jump \(attempt.index)") {
                if let h = attempt.heightMetres {
                    LabeledContent("Height") {
                        Text(String(format: "%.1f cm", 100 * h)).font(.title3.monospacedDigit())
                    }
                    if let u = attempt.uncertaintyMetres {
                        LabeledContent("From the camera clock") { Text(String(format: "± %.1f cm", 100 * u)).monospacedDigit() }
                    }
                    if let b = attempt.thresholdBiasMetres {
                        LabeledContent("Could read low by") { Text(String(format: "%.1f cm", 100 * b)).monospacedDigit() }
                    }
                    if let f = attempt.flightSeconds {
                        LabeledContent("Time in the air") { Text(String(format: "%.0f ms", 1000 * f)).monospacedDigit() }
                    }
                    if let fps = attempt.frameRate {
                        LabeledContent("Frames a second") { Text(String(format: "%.0f", fps)).monospacedDigit() }
                    }
                } else {
                    Text(attempt.unavailableReason ?? "no reason recorded").foregroundStyle(.orange)
                }
            }
            Section {
                if let r = attempt.hipRiseMetres {
                    LabeledContent("How far your hips rose") {
                        Text(String(format: "%.1f cm", 100 * r)).monospacedDigit()
                    }
                    if let u = attempt.hipRiseUncertaintyMetres {
                        LabeledContent("Give or take") { Text(String(format: "± %.1f cm", 100 * u)).monospacedDigit() }
                    }
                    if let c = attempt.comparisonSentence { Text(c).font(.footnote) }
                } else {
                    Text(attempt.hipUnavailableReason ?? "The hip cross-check did not run.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("The cross-check")
            } footer: {
                Text("Two ways of measuring the same jump. They should roughly agree; when they do not, the screen says which one to believe.")
            }
            if !attempt.notes.isEmpty {
                Section("How it was measured") {
                    ForEach(attempt.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section {
                LabeledContent("Phone time") { Text(String(format: "%.1f s", attempt.secondsAnalysed)).monospacedDigit() }
                LabeledContent("Filmed") { Text(attempt.recordedAt, format: .dateTime.day().month().hour().minute()) }
            }
        }
        .navigationTitle("Jump \(attempt.index)")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Past tests

struct JumpHistoryView: View {
    @Bindable var store: JumpStore

    var body: some View {
        List {
            if let err = store.loadError { Section { Text(err).foregroundStyle(.red) } }
            Section {
                Text(store.trendSentence).font(.footnote)
            } header: {
                Text("The trend")
            }
            if store.tests.isEmpty {
                Section { Text("No jump tests saved yet.").font(.footnote).foregroundStyle(.secondary) }
            } else {
                Section("Test days") {
                    ForEach(store.tests) { test in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(test.date, format: .dateTime.day().month().year()).font(.subheadline.weight(.semibold))
                            Text(test.line).font(.footnote).monospacedDigit()
                            let heights = test.measured.compactMap(\.heightMetres)
                            if !heights.isEmpty {
                                Text(heights.map { String(format: "%.1f", 100 * $0) }.joined(separator: " · ") + " cm")
                                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { store.delete(store.tests[i].id) }
                    }
                }
            }
        }
        .navigationTitle("Jump history")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { ActivityLog.shared.event("screen", ["name": "jump.history", "tests": store.tests.count]) }
    }
}
