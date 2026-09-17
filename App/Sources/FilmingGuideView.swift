import SwiftUI

/// The filming protocol (`docs/PHASE0-FILMING-PROTOCOL.md`, v1) as the app shows it. Every line is a
/// requirement the analysis actually has: the pipeline refuses a shot whose release or apex is out of
/// frame, calibrates from the rim's ellipse, and infers make/miss only when the ball can be seen at the rim.
struct FilmingGuideView: View {
    struct Step: Identifiable {
        var id: Int
        var title: String
        var detail: String
        var why: String
    }

    static let steps: [Step] = [
        Step(id: 1, title: "Tripod, lens at waist height",
             detail: "Lens 1.0–1.3 m above the floor. Not higher.",
             why: "Higher makes the rim's ellipse thinner, and a thin ellipse fixes the shot plane badly."),
        Step(id: 2, title: "Side view, 7–9 m from the shot line",
             detail: "On the sideline, opposite the midpoint between you and the rim. Landscape.",
             why: "The arc, release angle and entry angle are only measured in a side view."),
        Step(id: 3, title: "Slo-mo, 1× lens, never zoom",
             detail: "Camera app → Slo-mo. Settings → Camera → Record Slo-mo → 1080p at 240 fps if offered, otherwise 120.",
             why: "The release instant is found to a frame; more frames per second is more precision on the angle."),
        Step(id: 4, title: "Frame it, then lock focus",
             detail: "Feet at the bottom edge, rim in the top third, about a metre of air above the highest arc. Long-press on the shooter until AE/AF LOCK shows.",
             why: "A release or apex outside the frame is refused, not extrapolated. Refocusing mid-clip changes the ball's size."),
        Step(id: 5, title: "Do not touch the phone",
             detail: "Airplane mode, Do Not Disturb, wiped lens, plenty of storage. Start recording and leave it.",
             why: "The rim is calibrated once per clip. If the phone moves, the calibration is wrong for everything after."),
        Step(id: 6, title: "Say the shot number, then make or miss",
             detail: "Before each shot say its number. After it say “make” or “miss” (or “airball”, “rim out”, “bank”).",
             why: "The app infers the outcome from the ball at the rim and marks it unknown when it cannot; your voice is the record."),
        Step(id: 7, title: "15–25 shots per clip, one spot per clip",
             detail: "Stop, then start a new clip for a new spot. Keep the tripod where it is within a block.",
             why: "Findings need 30 accepted shots from one spot. Different spots are different shots and are never pooled."),
        Step(id: 8, title: "Measure and note",
             detail: "Tape-measure the lens height, the tripod to the point under the rim, and the tripod to your spot. Take a photo of the setup.",
             why: "These numbers are what a wrong calibration is checked against."),
    ]

    var body: some View {
        List {
            Section {
                Text("Four things have to be true for a clip to be measurable: the rim fully visible in some frames, the whole flight in frame from the hands to the rim, a phone that never moves, and make or miss on record. Everything below serves one of those.")
                    .font(.footnote)
            }
            ForEach(FilmingGuideView.steps) { step in
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(step.detail).font(.subheadline)
                        Label(step.why, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } header: {
                    Text("\(step.id) · \(step.title)")
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Phone 3–4 m from you, side-on, whole body in frame from the floor to a hand's width above your follow-through, 240 fps, good light. 10–15 shots. The rim does not need to be in frame.").font(.subheadline)
                    Label("At 9 m you are about 500 px tall and an ankle is a few pixels. At 3–4 m you are 1,500 px tall: joint angles become sub-degree, the fingers and the wrist snap are visible, and the neck, trunk, hip, knee and ankle chain can be read reliably.", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } header: {
                Text("Form clip — for the body")
            }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Phone directly behind you, 2–3 m back, lens at chest height, rim in the top third, 240 fps, good light. A strip of tape around the ball's equator helps. 10–15 shots.").font(.subheadline)
                    Label("The side view cannot see left-right or the spin axis. From behind, left-right deviation at the rim and the ball's rotation (backspin vs side-spin) become measurable; the spin tracker refuses on footage where the seams are not visible, which is what a dim 9 m clip is.", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } header: {
                Text("Behind clip — for left-right and rotation")
            }
            Section {
                Text("After a session, the Session screen's “How to film next time” card tells you which of these the footage actually broke — sky above the arc, outcomes not seen, a rim ellipse too thin — measured from the clip, not guessed.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .onAppear { ActivityLog.shared.event("screen", ["name": "filmingGuide"]) }
        .navigationTitle("How to film")
        .navigationBarTitleDisplayMode(.inline)
    }
}
