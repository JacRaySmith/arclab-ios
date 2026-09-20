import SceneKit
import SwiftUI
import UIKit

// ================================================================================================
// MARK: - The trainer
// ================================================================================================
//
// Eight plays. Each one runs in 3-D from the user's own eye height, stops dead at the moment the
// read has to be made, and starts a clock. The tap is recorded with the time it took, then the
// reason is shown with the cue ringed and the play runs out so the user sees what happened.
//
// What is measured: whether the tap matched the authored best read, and the milliseconds from the
// freeze to the tap. What is not measured, and so is never shown: anything that would look like a
// rating of the user. The reveal says plainly that the answers are coaching convention.

private struct IQSceneContainer: UIViewRepresentable {
    let scene: IQPlayScene

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = IQPalette.sky
        view.antialiasingMode = .multisampling2X
        view.isUserInteractionEnabled = false
        view.preferredFramesPerSecond = 60
        scene.attach(view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        scene.attach(view)
    }
}

struct IQTrainerView: View {
    var store: IQStore

    /// Eight plays, chosen so a session is never eight pick-and-rolls in a row.
    @State private var plan: [IQScenario] = []
    @State private var index = 0
    @State private var scene: IQPlayScene?
    @State private var sessionID: UUID?
    @State private var chosen: IQRead?
    @State private var decisionMs: Int?
    @State private var flash = false
    @State private var sessionPlays: [IQPlay] = []
    @State private var done = false
    /// Set when the screen goes away, so the half-second delay before a play starts cannot start
    /// one after the user has left.
    @State private var left = false

    private var scenario: IQScenario? { plan.indices.contains(index) ? plan[index] : nil }

    var body: some View {
        Group {
            if done {
                summary
            } else if let scenario, let scene {
                play(scenario: scenario, scene: scene)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Trainer")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard plan.isEmpty else { return }
            var generator = SystemRandomNumberGenerator()
            plan = IQScenarioLibrary.session(count: 8, using: &generator)
            sessionID = store.startSession()
            ActivityLog.shared.event("screen", ["name": "iq.trainer", "plays": plan.count])
            #if DEBUG
            let failures = IQScenarioLibrary.selfCheck() + IQMaths.selfCheck() + IQQuizBank.selfCheck()
            ActivityLog.shared.event("iq.selfcheck",
                                     ["failures": failures.count, "detail": failures.prefix(6).joined(separator: " | ")])
            #endif
            load(at: 0)
        }
        .onDisappear {
            left = true
            scene?.stop()
            if !done, let sessionID { store.endSession(sessionID) }
        }
    }

    // MARK: One play

    private func play(scenario: IQScenario, scene: IQPlayScene) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                IQSceneContainer(scene: scene)
                    .id(scenario.id)
                    .frame(maxWidth: .infinity)
                    .frame(height: 320)
                    .clipped()

                chrome(scenario: scenario, scene: scene)

                Rectangle().fill(.white)
                    .frame(height: 320)
                    .opacity(flash ? 0.9 : 0)
                    .allowsHitTesting(false)
            }
            .frame(height: 320)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if scene.state == .playing || scene.state == .ready {
                        watchingRow(scenario: scenario)
                    } else if chosen == nil {
                        decisionRows(scenario: scenario, scene: scene)
                    } else {
                        reveal(scenario: scenario, scene: scene)
                    }
                }
                .padding(16)
            }
        }
    }

    private func watchingRow(scenario: IQScenario) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Watch the play")
                .font(.headline)
            Text("It will stop. When it does, pick the read as fast as you can — the app times you from the freeze.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(scenario.situation)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func decisionRows(scenario: IQScenario, scene: IQPlayScene) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("What do you do?").font(.headline)
                Spacer()
                TimelineView(.periodic(from: .now, by: 0.05)) { _ in
                    Text(IQWording.time(ms: scene.decisionMilliseconds() ?? 0))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(scenario.reads) { read in
                Button {
                    choose(read, scenario: scenario, scene: scene)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(read.label).font(.body.weight(.semibold))
                        Text(read.action).font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func reveal(scenario: IQScenario, scene: IQPlayScene) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            let right = chosen?.isBest == true
            HStack(spacing: 10) {
                Image(systemName: right ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(right ? .green : .red)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(right ? "That is the read" : "The usual read is \(scenario.bestRead?.label ?? "—")")
                        .font(.headline)
                    Text("You decided in \(IQWording.time(ms: decisionMs))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }

            ForEach(scenario.reads) { read in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: read.isBest ? "checkmark" : (read.id == chosen?.id ? "xmark" : "circle"))
                        .font(.caption)
                        .foregroundStyle(read.isBest ? .green : (read.id == chosen?.id ? .red : .secondary))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(read.label).font(.subheadline.weight(read.isBest ? .semibold : .regular))
                        Text(read.action).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Text(scenario.why)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            if let cue = scenario.cueActorID,
               let actor = scenario.actors.first(where: { $0.id == cue }) {
                Label("Ringed in yellow: \(actor.label)", systemImage: "circle.dashed")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Text("Source: \(scenario.source) Evidence grade \(scenario.evidenceGrade) — good coaches disagree about some of these.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                next()
            } label: {
                Text(index + 1 >= plan.count ? "Finish" : "Next play")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
    }

    // MARK: The overlay on the picture

    private func chrome(scenario: IQScenario, scene: IQPlayScene) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    if let seconds = scenario.clockSeconds, let label = scenario.clockLabel {
                        VStack(spacing: 0) {
                            Text(label).font(.caption2)
                            Text("\(Int(seconds))").font(.title3.monospacedDigit().weight(.bold))
                        }
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if scene.state == .frozen {
                        Text("FROZEN")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.yellow, in: Capsule())
                    }
                }
                .padding(8)
            }

            Spacer()

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Play \(index + 1) of \(plan.count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.75))
                    Text(scenario.situation)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 215, alignment: .leading)
                .padding(8)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .padding(.leading, 8)
                Spacer(minLength: 4)
                IQMiniMapView(scenario: scenario, time: scene.mapTime,
                              highlight: chosen == nil ? nil : scenario.cueActorID)
                    .frame(width: 104, height: 98)
                    .padding(8)
            }
        }
        .frame(height: 320)
        .allowsHitTesting(false)
    }

    // MARK: Session flow

    private func load(at i: Int) {
        guard plan.indices.contains(i) else { return }
        chosen = nil
        decisionMs = nil
        let built = IQPlayScene(scenario: plan[i])
        built.onFreeze = {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            withAnimation(.easeOut(duration: 0.06)) { flash = true }
            withAnimation(.easeIn(duration: 0.22).delay(0.06)) { flash = false }
        }
        scene = built
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            if scene === built, !left { built.start() }
        }
    }

    private func choose(_ read: IQRead, scenario: IQScenario, scene: IQPlayScene) {
        guard chosen == nil, scene.state == .frozen else { return }
        let ms = scene.decisionMilliseconds() ?? 0
        chosen = read
        decisionMs = ms
        let play = IQPlay(id: UUID(), scenarioID: scenario.id, principle: scenario.principle,
                          correct: read.isBest, decisionMs: ms, at: Date())
        sessionPlays.append(play)
        if let sessionID { store.record(play: play, in: sessionID) }
        scene.reveal()
    }

    private func next() {
        scene?.stop()
        if index + 1 >= plan.count {
            if let sessionID { store.endSession(sessionID) }
            done = true
            return
        }
        index += 1
        load(at: index)
    }

    // MARK: The end of the session

    private var summary: some View {
        List {
            Section("This session") {
                LabeledContent("Reads", value: IQWording.fraction(correct: sessionPlays.filter(\.correct).count,
                                                                  of: sessionPlays.count))
                LabeledContent("Median decision",
                               value: "\(IQWording.time(ms: IQMaths.median(sessionPlays.map(\.decisionMs)))) (n \(sessionPlays.count))")
            }
            Section("Play by play") {
                ForEach(sessionPlays) { play in
                    HStack {
                        Image(systemName: play.correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(play.correct ? .green : .red)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(IQScenarioLibrary.scenario(id: play.scenarioID)?.title ?? "Play")
                                .font(.subheadline)
                            Text(play.principle.title).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(IQWording.time(ms: play.decisionMs))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Text("""
                These answers are what coaches teach, not results measured from tracking data, so \
                treat a wrong answer as a conversation rather than a verdict. The one thing here \
                that is measured is your decision time, and it is shown with how many plays it \
                came from.
                """)
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Session")
    }
}
