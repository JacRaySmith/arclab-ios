import ShotGeometry
import SwiftUI

// MARK: - Shared row style

/// The evidence-grade capsule, the same shape and colours as `ShotProfileView`'s, for the package's
/// own `ShotEvidenceGrade`.
struct DoctorGradeBadge: View {
    let grade: ShotEvidenceGrade

    var body: some View {
        Text(grade.letter)
            .font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(colour.opacity(0.18), in: Capsule())
            .foregroundStyle(colour)
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

/// Supported / not supported / cannot be measured — the status of one evidence test.
struct DoctorVerdictChip: View {
    let verdict: HypothesisVerdict

    var body: some View {
        Text(DoctorNames.verdict(verdict))
            .font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(colour.opacity(0.15), in: Capsule())
            .foregroundStyle(colour)
    }

    private var colour: Color {
        switch verdict {
        case .supported: return .green
        case .notSupported: return .secondary
        case .belowFloor: return .orange
        case .needsAnotherClip: return .blue
        case .noData: return .secondary
        case .descriptive: return .purple
        }
    }
}

// MARK: - Ask

/// "Ask about your shot": say what feels wrong, in your own words or from the list, and get back
/// the mechanisms behind that complaint, each one tested against your own saved shots.
///
/// The matcher is deterministic and on-device: it lower-cases, strips punctuation and scores
/// whole-word phrase hits. When nothing matches it says so and shows the list rather than guessing
/// (`docs/DESIGN-SHOT-DOCTOR-2026-09-14.md` §5).
struct AskView: View {
    @Bindable var doctor: ShotDoctorModel
    @State private var showPicker = false
    @FocusState private var typing: Bool

    var body: some View {
        List {
            if let reason = doctor.unavailableReason {
                Section {
                    Text(reason).font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                askSection
                if let answer = doctor.answer {
                    matchSection(answer)
                    rankedSection(answer)
                    planSection(answer)
                    honestySection(answer)
                }
                if doctor.answer == nil || showPicker { pickerSection }
            }
        }
        .navigationTitle("Ask about your shot")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            ActivityLog.shared.event("screen", [
                "name": "doctor.ask", "sessions": doctor.store.sessions.count,
                "shots": doctor.records.count,
            ])
        }
    }

    // MARK: Free text

    private var askSection: some View {
        Section {
            TextField("What feels wrong? e.g. \"I keep coming up short from three\"", text: $doctor.complaint, axis: .vertical)
                .lineLimit(1...4)
                .focused($typing)
            Button {
                typing = false
                showPicker = false
                doctor.answerFreeText()
            } label: {
                Label("Ask", systemImage: "stethoscope")
            }
            .disabled(doctor.complaint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } header: {
            Text("In your own words")
        } footer: {
            Text("Matched on this device against \(SymptomLibrary.all.count) known complaints, by whole-word phrases only — no model, nothing leaves the phone. If nothing matches, the list below is shown instead of a guess.")
        }
    }

    // MARK: What it matched

    private func matchSection(_ answer: ComplaintAnswer) -> some View {
        Section {
            if let reason = answer.unmatchedReason {
                Text(reason).font(.footnote).foregroundStyle(.orange)
            } else if let symptom = answer.symptom {
                VStack(alignment: .leading, spacing: 4) {
                    Text(symptom.title).font(.subheadline.bold())
                    Text(symptom.restatement).font(.footnote)
                    if let top = answer.matches.first, !top.matchedPhrases.isEmpty {
                        Text("Matched on \(top.matchedPhrases.map { "\"\($0)\"" }.joined(separator: ", ")).")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else if doctor.pickedSymptom != nil {
                        Text("Picked from the list, so the matcher was not used.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if let spot = answer.focusSpot {
                        Text("Answered from your \(spot.displayLower) shots — the spot with the most accepted shots. Spots are never pooled.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if answer.matches.count > 1 {
                    Text("Other complaints it also matched: \(answer.matches.dropFirst().prefix(3).map(\.symptom.title).joined(separator: "; ")).")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Button("Pick a different symptom") { showPicker = true }
                    .font(.subheadline)
            }
        } header: {
            Text("What this was read as")
        }
    }

    // MARK: Ranked hypotheses

    private func rankedSection(_ answer: ComplaintAnswer) -> some View {
        Group {
            if !answer.ranked.isEmpty {
                Section {
                    ForEach(Array(answer.ranked.enumerated()), id: \.offset) { _, e in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(DoctorNames.hypothesis(e.hypothesis.id)).font(.subheadline.bold())
                                Spacer()
                                DoctorGradeBadge(grade: e.hypothesis.grade)
                            }
                            DoctorVerdictChip(verdict: e.verdict)
                            Text(e.hypothesis.statement).font(.footnote)
                            Text(e.evidenceLine).font(.caption).foregroundStyle(.primary)
                            if let film = e.filmThis {
                                Label(film, systemImage: "video.badge.plus")
                                    .font(.caption).foregroundStyle(.blue)
                            }
                            Text(e.hypothesis.source).font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } header: {
                    Text("What could be behind it")
                } footer: {
                    Text("Supported first, then the tests that could not run, then what was ruled out. Nothing is hidden: a test that failed is still listed. A = peer-reviewed measurement on skilled shooters or exact geometry; B = smaller or indirect; C = coaching consensus; D = untested. Every line is an association inside your own shooting.")
                }
            }
        }
    }

    // MARK: The one fix

    private func planSection(_ answer: ComplaintAnswer) -> some View {
        Group {
            if let plan = answer.plan {
                Section {
                    NavigationLink {
                        PlanView(doctor: doctor, package: plan, symptom: answer.symptom?.id,
                                 spot: spot(for: answer))
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(DoctorNames.hypothesis(plan.hypothesis)).font(.subheadline.bold())
                                Spacer()
                                DoctorGradeBadge(grade: plan.grade)
                            }
                            Text(plan.cue).font(.footnote)
                            Text("\(plan.drill.name) — \(plan.drill.sets) × \(plan.drill.reps)").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } header: {
                    Text("The one fix this points to")
                } footer: {
                    Text("One fix at a time: the app scores exactly one plan, because two changes at once means neither can be scored.")
                }
            }
        }
    }

    private func spot(for answer: ComplaintAnswer) -> ShotSpot {
        answer.focusSpot.flatMap { ShotSpot(rawValue: $0.rawValue) } ?? doctor.busiestSpot ?? .other
    }

    private func honestySection(_ answer: ComplaintAnswer) -> some View {
        Section("How to read all of this") {
            ForEach(Array(answer.honesty.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: The taxonomy

    private var pickerSection: some View {
        Section {
            ForEach(SymptomLibrary.all, id: \.id) { symptom in
                Button {
                    doctor.complaint = ""
                    showPicker = false
                    doctor.ask(symptom: symptom.id)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(symptom.title).font(.subheadline)
                        Text("\(symptom.hypotheses.count) mechanism\(symptom.hypotheses.count == 1 ? "" : "s") behind it")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Or pick what it feels like")
        } footer: {
            Text("These \(SymptomLibrary.all.count) are every complaint the engine knows. Picking one skips the matcher.")
        }
    }
}
