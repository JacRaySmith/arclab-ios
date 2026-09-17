import ShotGeometry
import SwiftUI

/// "Plan": exactly one fix, as a package — the cue, the drill, the measure that should move, what
/// would count as a change, and how the app checks it (`docs/DESIGN-SHOT-DOCTOR-2026-09-14.md` §6).
///
/// Starting a plan records a baseline: which session, and what that session's number for the pass
/// measure actually was. After the next session at the same spot is saved, the pass check appears
/// with its numbers; after the one after that, the retention result. `passed` and `held` are
/// `Bool?` — nil is never a fail, and the sentence says why it could not be told.
struct PlanView: View {
    @Bindable var doctor: ShotDoctorModel
    let package: FixPackage
    let symptom: SymptomID?
    let spot: ShotSpot

    @State private var showReplace = false

    var body: some View {
        List {
            headerSection
            drillSection
            measureSection
            checkSection
            progressSection
            actionSection
            honestySection
        }
        .navigationTitle("Plan")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            doctor.recordPlanSessions()
            ActivityLog.shared.event("screen", [
                "name": "doctor.plan", "hypothesis": package.hypothesis.rawValue,
                "spot": spot.rawValue, "active": isActive,
            ])
        }
        .confirmationDialog("One fix at a time", isPresented: $showReplace, titleVisibility: .visible) {
            Button("Replace the active plan", role: .destructive) { start() }
            Button("Keep the current plan", role: .cancel) {}
        } message: {
            Text(activeOther.map { "\(DoctorNames.hypothesis($0.package.hypothesis)) is being scored right now. Starting this one drops it, and whatever it had measured so far stops being comparable." } ?? "")
        }
    }

    private var progress: ShotDoctorModel.PlanProgress? { doctor.planProgress }
    private var isActive: Bool { doctor.store.activePlan?.hypothesis == package.hypothesis.rawValue }
    private var activeOther: ShotDoctorModel.PlanProgress? {
        guard let p = progress, p.package.hypothesis != package.hypothesis else { return nil }
        return p
    }

    // MARK: The fix

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(DoctorNames.hypothesis(package.hypothesis)).font(.headline)
                    Spacer()
                    DoctorGradeBadge(grade: package.grade)
                }
                Label(package.cue, systemImage: "target").font(.subheadline)
                Text(package.source).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The plan says what to do; the module says why, where it sits in the order a coach
            // teaches, and which faults share its fingerprint (`ShotGeometry/Curriculum.swift`).
            if let module = Curriculum.module(for: package.hypothesis) {
                NavigationLink {
                    LearnModuleView(module: module, practice: nil, doctor: doctor, store: doctor.store)
                } label: {
                    Label("Learn why — \(module.title)", systemImage: "graduationcap")
                        .font(.subheadline)
                }
            }
        } header: {
            Text("The cue")
        } footer: {
            Text("The grade is on the evidence that this measure matters, not on the wording of the cue. The cue is a way of carrying the change into the shot; the measured change is the evidence it worked.")
        }
    }

    private var drillSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(package.drill.name).font(.subheadline.bold())
                Text("\(package.drill.sets) sets × \(package.drill.reps) shots — \(package.drill.totalShots) in all")
                    .font(.footnote.monospacedDigit())
                Text(package.drill.spots.isEmpty
                     ? "At \(spot.rawValue.lowercased()), where the finding was made."
                     : "Spots: \(package.drill.spots.map(\.rawValue).joined(separator: ", "))")
                    .font(.footnote)
                Text(package.drill.constraint).font(.footnote)
                Text(package.drill.schedule).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } header: {
            Text("The drill")
        }
    }

    private var measureSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(package.measureThatShouldMove).font(.subheadline)
                Text(package.expectedMagnitude).font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let trial = package.trialSuggestion {
                Label(trial, systemImage: "flask").font(.caption)
            }
        } header: {
            Text("What should move, and by how much")
        } footer: {
            Text("The magnitude is written against what can be seen at these shot counts, not as a promise. A change smaller than the spread of the measure cannot be told from chance however real it is.")
        }
    }

    private var checkSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(package.passCheck.description).font(.footnote)
                Text("Measure: \(PracticeNames.measure(package.passCheck.measure).name) · at least \(package.passCheck.minimumN) accepted shots in the next session, or the check says it cannot tell.")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(package.retentionRule).font(.footnote)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } header: {
            Text("How the app checks it")
        } footer: {
            Text("The check runs by itself on the next session you save at this spot. Nothing is ever scored a failure for want of shots — that comes back as \"not enough shots to tell\".")
        }
    }

    // MARK: Baseline, check, retention

    private var progressSection: some View {
        Group {
            if isActive, let p = progress {
                Section {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Baseline").font(.caption.bold())
                        Text("\(p.plan.baselineSessionDate, format: .dateTime.day().month().year().hour().minute()) at \(p.plan.spot.rawValue), n = \(p.plan.baselineAcceptedShots) accepted shots.")
                            .font(.caption)
                        if let v = p.plan.baselineValue {
                            Text(String(format: "%@ = %.3f at the start.", p.plan.baselineMeasure, v))
                                .font(.caption.monospacedDigit())
                        } else if let why = p.plan.baselineUnavailableReason {
                            Text(why).font(.caption).foregroundStyle(.secondary)
                        }
                        if let why = p.baselineUnavailableReason {
                            Text(why).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Next-session check").font(.caption.bold())
                        if let check = p.check, let session = p.followUp {
                            resultRow(passed: check.passed)
                            Text(check.sentence).font(.caption)
                            Text("From \(session.date, format: .dateTime.day().month().year().hour().minute())\(check.n.map { ", n = \($0) accepted shots" } ?? "").")
                                .font(.caption2).foregroundStyle(.secondary)
                        } else if let why = p.followUpUnavailableReason {
                            Text(why).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Did it stick").font(.caption.bold())
                        if let r = p.retentionResult, let session = p.retention {
                            resultRow(passed: r.held)
                            Text(r.sentence).font(.caption)
                            Text("Against \(session.date, format: .dateTime.day().month().year().hour().minute()).")
                                .font(.caption2).foregroundStyle(.secondary)
                        } else if let why = p.retentionUnavailableReason {
                            Text(why).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Retention is judged on the session after the follow-up, not on the one you practised in.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } header: {
                    Text("How this plan is going")
                } footer: {
                    Text("The score of a fix is what survives to the session after, not what happened at the end of the one you drilled it in.")
                }
            }
        }
    }

    /// Bool? with nil never shown as a failure.
    private func resultRow(passed: Bool?) -> some View {
        let text: String
        let colour: Color
        switch passed {
        case .some(true): text = "passed"; colour = .green
        case .some(false): text = "not yet"; colour = .orange
        case nil: text = "cannot tell yet"; colour = .secondary
        }
        return Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(colour.opacity(0.15), in: Capsule())
            .foregroundStyle(colour)
    }

    // MARK: Start / stop

    private var actionSection: some View {
        Section {
            if isActive {
                Button(role: .destructive) {
                    doctor.clearPlan()
                } label: {
                    Label("Stop this plan", systemImage: "stop.circle")
                }
            } else if activeOther != nil {
                Button {
                    showReplace = true
                } label: {
                    Label("Start this plan instead", systemImage: "arrow.triangle.2.circlepath")
                }
                if let other = activeOther {
                    Text("Currently scoring: \(DoctorNames.hypothesis(other.package.hypothesis)) at \(other.spot.rawValue), chosen \(other.plan.chosenDate, format: .dateTime.day().month().year()).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if doctor.store.sessions(at: spot).isEmpty {
                Text("There is no saved session at \(spot.rawValue.lowercased()) to take a baseline from. Save one with that spot and the plan can be started and scored.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Button {
                    start()
                } label: {
                    Label("Start this plan", systemImage: "play.circle")
                }
            }
        } footer: {
            Text("Starting records the baseline: the session it was read from, its accepted-shot count, and that session's own number for the measure above.")
        }
    }

    private func start() {
        doctor.startPlan(hypothesis: package.hypothesis, symptom: symptom, spot: spot)
        doctor.recordPlanSessions()
    }

    private var honestySection: some View {
        Section("The rules this plan is held to") {
            ForEach(Array(FixLibrary.honestyRules.enumerated()), id: \.offset) { _, rule in
                Text(rule).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
