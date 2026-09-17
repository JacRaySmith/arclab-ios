import ShotGeometry
import SwiftUI

/// "Diagnosis and plan": what the engine found in the saved shots at one spot, without being asked a
/// question first (`docs/DESIGN-SHOT-DOCTOR-2026-09-14.md` §3–4).
///
/// Four things: where the front-to-back spread comes from, how the shot changes with distance, the
/// arc geometry, and the most recent session's misses written out as arithmetic. Nothing below its
/// shot floor is presented as a finding — the engine's own flags decide that, and this screen shows
/// the reason it gives rather than a blank.
struct DiagnosisView: View {
    @Bindable var doctor: ShotDoctorModel
    @State private var spot: ShotSpot = .freeThrow

    var body: some View {
        List {
            if let reason = doctor.unavailableReason {
                Section { Text(reason).font(.footnote).foregroundStyle(.secondary) }
            } else if let diagnosis = doctor.diagnosis {
                spotPicker
                planLink
                depthSection(diagnosis)
                distanceSection(diagnosis)
                arcSection(diagnosis)
                missSection
                notesSection(diagnosis)
            }
        }
        .navigationTitle("Diagnosis")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let best = doctor.busiestSpot { spot = best }
            ActivityLog.shared.event("screen", [
                "name": "doctor.diagnosis", "spot": spot.rawValue,
                "shots": doctor.records.count, "sessions": doctor.store.sessions.count,
            ])
        }
    }

    private var doctorSpot: DoctorSpot { DoctorSpot(rawValue: spot.rawValue) ?? .other }
    private var spotDiagnosis: SpotDiagnosis? { doctor.diagnosis?.spot(doctorSpot) }

    private var spotPicker: some View {
        Section {
            Picker("Spot", selection: $spot) {
                ForEach(doctor.spotsWithData) { s in
                    Text("\(s.rawValue) (\(doctor.diagnosis?.spot(DoctorSpot(rawValue: s.rawValue) ?? .other)?.n ?? 0))").tag(s)
                }
            }
            .pickerStyle(.menu)
            if let d = spotDiagnosis {
                Text(d.headline).font(.footnote)
                Text("\(d.n) accepted shots here: \(d.makes) inferred make, \(d.misses) inferred miss, \(d.unknownOutcomes) outcome not seen.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } footer: {
            Text("Every number on this screen comes from this spot only. Two distances are two different shots and are never averaged together.")
        }
    }

    private var planLink: some View {
        Section {
            if let progress = doctor.planProgress {
                NavigationLink {
                    PlanView(doctor: doctor, package: progress.package,
                             symptom: progress.plan.symptom.flatMap(SymptomID.init(rawValue:)),
                             spot: progress.spot)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Active plan — \(DoctorNames.hypothesis(progress.package.hypothesis))")
                            .font(.subheadline.bold())
                        Text("Chosen \(progress.plan.chosenDate, format: .dateTime.day().month().year()) at \(progress.plan.spot.rawValue)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                NavigationLink {
                    AskView(doctor: doctor)
                } label: {
                    Label("Ask about your shot to get a plan", systemImage: "stethoscope")
                }
            }
        }
    }

    // MARK: Where the depth spread comes from

    private func depthSection(_ diagnosis: Diagnosis) -> some View {
        Group {
            if let d = spotDiagnosis {
                Section {
                    if let cause = d.dominantCause {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Mostly \(cause.channel)").font(.subheadline.bold())
                            Text(cause.sentence).font(.footnote)
                            Text(String(format: "%.0f %% of the predicted front-to-back variance, n = %d.", cause.share * 100, cause.n))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let a = d.attribution {
                        shareRow("Release speed", a.speedShare)
                        shareRow("Release angle", a.thetaShare)
                        shareRow("Release height", a.heightShare)
                        shareRow("How they move together", a.covarianceShare)
                        LabeledContent("Predicted depth spread") {
                            Text(String(format: "%.0f cm (n = %d)", a.sdDepth * 100, d.n)).font(.subheadline.monospacedDigit())
                        }
                        .font(.subheadline)
                    } else if let why = d.attributionUnavailableReason {
                        Text(why).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let observed = d.observedDepth {
                        LabeledContent("Measured depth past the front rim") {
                            Text(String(format: "%.0f ± %.0f cm (n = %d)", observed.mean * 100, observed.sd * 100, observed.n))
                                .font(.subheadline.monospacedDigit())
                        }
                        .font(.subheadline)
                    }
                    if let op = d.operatingPoint {
                        Text(String(format: "At this spot's average release, 0.1 m/s of speed is worth %.0f cm of depth — that is what makes speed, angle and height comparable.", op.cmPerTenthOfSpeed))
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let why = d.operatingPointUnavailableReason {
                        Text(why).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("What your depth spread is made of")
                } footer: {
                    Text("Shares are of the spread the three release channels predict, not of the makes. A share above 100 % is possible and correct when two channels cancel. Below \(ShotDoctor.attributionFloor) shots the engine refuses this line rather than quoting it.")
                }
            }
        }
    }

    private func shareRow(_ label: String, _ share: Double) -> some View {
        LabeledContent(label) {
            Text(String(format: "%.0f %%", share * 100)).font(.subheadline.monospacedDigit())
        }
        .font(.subheadline)
    }

    // MARK: Distance

    private func distanceSection(_ diagnosis: Diagnosis) -> some View {
        let distance = diagnosis.distance
        return Group {
            Section {
                if let why = distance.unavailableReason {
                    Text(why).font(.footnote).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(verdictTitle(distance.versatility.verdict)).font(.subheadline.bold())
                            Spacer()
                            DoctorGradeBadge(grade: distance.versatility.grade)
                        }
                        Text(distance.versatility.sentence).font(.footnote)
                        if let ratio = distance.versatility.speedSDRatio, let floor = distance.versatility.detectableRatio {
                            Text(String(format: "Far ÷ near release-speed spread %.2f×, against the %.2f× these shot counts could tell from chance.", ratio, floor))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(distance.versatility.source).font(.caption2).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(Array(distance.profiles.enumerated()), id: \.offset) { _, p in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(p.spot.rawValue).font(.caption.bold())
                                Spacer()
                                Text("n = \(p.n) · \(p.makes) make, \(p.misses) miss").font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(profileLine(p)).font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !distance.trends.isEmpty {
                        DisclosureGroup("Near to far, measure by measure") {
                            ForEach(Array(distance.trends.enumerated()), id: \.offset) { _, t in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.label).font(.caption.bold())
                                    Text(trendLine(t)).font(.caption2).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .font(.subheadline)
                    }
                    ForEach(Array(distance.statements.enumerated()), id: \.offset) { _, s in
                        Text(s).font(.caption)
                    }
                }
            } header: {
                Text("Does the shot hold together with distance")
            } footer: {
                Text("A spot enters this comparison at \(ShotDoctor.spotFloor) accepted shots. The only published definition of versatility is spread stability — skilled shooters' release-speed spread was the same at the line and at three — so that is what is compared, not a target anyone has to hit.")
            }
        }
    }

    private func verdictTitle(_ v: VersatilityVerdict) -> String {
        switch v {
        case .spreadStable: return "Spread holds with distance"
        case .spreadWidens: return "Spread widens with distance"
        case .spreadNarrows: return "Spread narrows with distance"
        case .undecided: return "Not enough to say either way"
        }
    }

    private func profileLine(_ p: SpotProfile) -> String {
        var bits: [String] = []
        if let d = p.distance {
            bits.append(String(format: "%.2f m from the rim (%@)", d, p.distanceIsMeasured ? "measured" : "nominal, not measured"))
        }
        if let v = p.releaseSpeed { bits.append(String(format: "speed %.2f ± %.2f m/s (n %d)", v.mean, v.sd, v.n)) }
        if let a = p.releaseAngle?.inDegrees { bits.append(String(format: "release %.1f ± %.1f° (n %d)", a.mean, a.sd, a.n)) }
        if let e = p.entryAngle?.inDegrees { bits.append(String(format: "entry %.1f ± %.1f° (n %d)", e.mean, e.sd, e.n)) }
        if let d = p.depthPastFrontRim { bits.append(String(format: "depth %.0f ± %.0f cm (n %d)", d.mean * 100, d.sd * 100, d.n)) }
        if let l = p.lateralDeviation { bits.append(String(format: "left-right %.0f ± %.0f cm (n %d)", l.mean * 100, l.sd * 100, l.n)) }
        if let t = p.dipToRelease { bits.append(String(format: "rhythm %.2f ± %.2f s (n %d)", t.mean, t.sd, t.n)) }
        return bits.isEmpty ? "nothing measurable from these clips" : bits.joined(separator: " · ")
    }

    private func trendLine(_ t: DistanceTrend) -> String {
        var s = String(format: "%@ %.2f → %@ %.2f %@ (n %d → %d)", t.nearSpot.rawValue, t.near, t.farSpot.rawValue, t.far, t.unit, t.nearN, t.farN)
        if let slope = t.slopePerMetre { s += String(format: ", %.3f %@ per metre", slope, t.unit) }
        if let ratio = t.ratio { s += String(format: ", %.2f×", ratio) }
        return s
    }

    // MARK: Arc

    private func arcSection(_ diagnosis: Diagnosis) -> some View {
        Group {
            if let p = diagnosis.profile(doctorSpot), let entry = p.entryAngle?.inDegrees {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Entry angle").font(.subheadline.bold())
                            Spacer()
                            DoctorGradeBadge(grade: .a)
                        }
                        Text(String(format: "%.1f ± %.1f° below horizontal, n = %d.", entry.mean, entry.sd, entry.n))
                            .font(.footnote.monospacedDigit())
                        Text(entrySentence(entry.mean, n: entry.n)).font(.footnote)
                        if let d = spotDiagnosis, let c = d.centroid {
                            Text(c.sourceSentence).font(.caption2).foregroundStyle(.secondary)
                        } else if let why = spotDiagnosis?.centroidUnavailableReason {
                            Text(why).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } header: {
                    Text("Arc geometry")
                } footer: {
                    Text("This one is geometry, not a study: the ball is 24 cm across and the ring 45.7 cm, so the room the ball has to pass through follows from the entry angle alone. It is a margin, not a target — no entry angle is prescribed here.")
                }
            }
        }
    }

    private func entrySentence(_ degrees: Double, n: Int) -> String {
        if degrees < 40 {
            return String(format: "Below 40° the ball has under about 3 cm of room front to back as it passes the ring. At %.1f° (n = %d) that margin is associated with depth errors turning into rim contact sooner than a steeper entry would.", degrees, n)
        }
        return String(format: "At %.1f° (n = %d) the ball has room to pass the ring; the geometric margin is not the thing limiting this spot.", degrees, n)
    }

    // MARK: The most recent session's misses

    private var missSection: some View {
        Group {
            if let session = doctor.latestSession(at: spot) {
                let d = doctor.diagnosis(for: session).spot(doctorSpot)
                Section {
                    Text("\(session.date, format: .dateTime.day().month().year().hour().minute()) · \(session.clipName)")
                        .font(.caption2).foregroundStyle(.secondary)
                    if let d, !d.missDecompositions.isEmpty {
                        ForEach(Array(d.missDecompositions.enumerated()), id: \.offset) { _, m in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text("Shot \(m.shotID)").font(.caption.bold())
                                    Spacer()
                                    Text(missDirection(m.direction)).font(.caption2).foregroundStyle(.secondary)
                                }
                                Text(m.sentence).font(.caption)
                                if let reason = m.lateralUnavailableReason {
                                    Text(reason).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else if let d, let why = d.centroidUnavailableReason {
                        Text(why).font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("No miss in that session could be written out: a miss needs a rim crossing and a reference to measure it against.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let d {
                        ForEach(Array(d.honesty.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Last session's misses, one by one")
                } footer: {
                    Text("Each line converts release speed, angle and height into centimetres of depth at this spot, then states what is left over. The leftover is never hidden — it is the part none of the three explains.")
                }
            }
        }
    }

    private func missDirection(_ d: MissDirection) -> String {
        d == .onLine ? "on line" : d.rawValue
    }

    // MARK: How to read it

    private func notesSection(_ diagnosis: Diagnosis) -> some View {
        Section("How to read all of this") {
            ForEach(Array(diagnosis.notes.enumerated()), id: \.offset) { _, n in
                Text(n).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(FixLibrary.honestyRules.enumerated()), id: \.offset) { _, r in
                Text(r).font(.caption).foregroundStyle(.secondary)
            }
            Text("Floors: your own makes become the reference at \(ShotDoctor.ownMakesFloor) makes, the depth-spread attribution at \(ShotDoctor.attributionFloor) shots, a spot joins the distance comparison at \(ShotDoctor.spotFloor).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
