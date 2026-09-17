import Foundation
import ShotGeometry
import simd

// ================================================================================================
// MARK: - The ghost: the shooter's own best reps
// ================================================================================================
//
// 1.2 item 19, sharpened by the outside research (docs/IMPROVEMENTS-2026-09-16.md §7): a **self**
// model beats an expert model (grade B), so the translucent form drawn behind the solid one is the
// shooter's own best reps at this spot — never a pro, never a population.
//
// "Best" is made only of numbers the app already measured, and the rule itself lives in ShotGeometry
// (`FormModel.bestReps`, with its unit tests). This file is the glue: it finds the reps to offer the
// rule in the shooter's saved sessions, builds the mean form of whatever comes back, and hands the
// screen a sentence for the legend. When the rule cannot find five, the ghost is the block mean and
// the legend says so with the counts in it.

struct FormGhost: Sendable {
    /// What to draw translucent. Never drawn when `unavailableReason` is set.
    var model: FormModel
    /// One line for the legend, over the scene.
    var legend: String
    /// The longer sentence for the provenance card.
    var provenance: String
    /// True when the best-rep rule was satisfied; false when this is the block mean instead.
    var isBestRepGhost: Bool
    /// Why there is no ghost at all.
    var unavailableReason: String?

    var isAvailable: Bool { unavailableReason == nil && model.isAvailable }

    static func unavailable(_ why: String) -> FormGhost {
        FormGhost(model: .unavailable(why), legend: "no ghost — " + why, provenance: why,
                  isBestRepGhost: false, unavailableReason: why)
    }
}

enum FormGhostBuilder {

    /// The saved sessions, read straight off the file the store keeps them in.
    ///
    /// Not `SessionStore`: that class is main-actor, and this is called from a detached task so the
    /// decode of every form of every session never lands on the frame the viewer is looking at.
    /// A file that cannot be read is no sessions — the ghost then says it found none of the
    /// shooter's own reps, which is true.
    static func savedSessions(at url: URL) -> [SavedSession] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([SavedSession].self, from: data)) ?? []
    }

    /// Build the ghost for one screen.
    ///
    /// - Parameters:
    ///   - model: the block this screen is about. It is the fallback ghost, and the unit every
    ///     candidate rep has to match.
    ///   - shot: the shot drawn solid, when there is one — the ghost has to be in its unit too.
    ///   - sessions: every saved session, as the store has them.
    ///
    /// Pure apart from reading the array it is handed, so it can run off the main actor.
    static func build(model: FormModel, shot: ShotForm?, sessions: [SavedSession]) -> FormGhost {
        // Which spot the ghost may draw from. A block built on the results screen carries none, and
        // pooling spots is not allowed: free throws and threes are released at different speeds, so
        // one pooled "within 1 SD of your own speed" band would be a band around neither. The screen
        // then matches the drawn shot to the saved session it came from — the forms are equal only if
        // it is the same shot — and refuses rather than mixing when even that finds nothing.
        var spot = model.spot
        var matchNote = ""
        if spot == nil, let shot, let owner = sessions.first(where: { s in s.shots.contains { $0.form == shot } }) {
            spot = owner.spot.rawValue
            matchNote = "This block did not say which spot it was shot from; it was matched to your saved \(owner.spot.rawValue) session by this shot's own form."
        }
        guard let spot else {
            return blockMeanGhost(model,
                                  why: "ghost = block mean; this screen was not told which spot the block was shot from, and best reps are not pooled across spots — a free throw and a three are not released at the same speed")
        }
        // The pool: the shooter's own accepted shots at this spot. Form clips are left out — they
        // carry no crossing depth and no release speed at all, so they can only dilute the rule.
        let atSpot = sessions.filter { !$0.isFormClip && $0.spot.rawValue == spot }
        var reps: [FormRep] = []
        for session in atSpot {
            for s in session.shots {
                guard let form = s.form else { continue }
                reps.append(FormRep(shotID: form.shotID ?? s.id, form: form,
                                    accepted: s.verdict == "accept",
                                    depthPastFrontRim: s.depthPastFrontRim,
                                    releaseSpeed: s.releaseSpeed))
            }
        }
        let poolNote = (reps.isEmpty
            ? "No saved session at \(spot) carries a 3-D form yet, so there are no reps of your own to choose from."
            : "Chosen from \(reps.count) saved shot\(reps.count == 1 ? "" : "s") at \(spot)\(atSpot.count == 1 ? " in 1 session" : " across \(atSpot.count) sessions").")
            + (matchNote.isEmpty ? "" : " " + matchNote)

        guard !reps.isEmpty else { return blockMeanGhost(model, why: poolNote) }

        let best = FormModel.bestReps(reps)
        guard best.isBestRepGhost else {
            return blockMeanGhost(model, why: best.legend, extra: poolNote)
        }
        let built = FormModel.build(forms: best.forms, label: "your best reps", spot: spot)
        guard built.isAvailable else {
            return blockMeanGhost(model,
                                  why: "ghost = block mean; your \(best.chosen) best reps do not average: "
                                    + (built.unavailableReason ?? "they were built on different grids"),
                                  extra: poolNote)
        }
        // Metres and shooter heights do not share a scale, so a ghost in the other unit is refused
        // rather than drawn at the wrong size.
        if let mismatch = unitMismatch(ghost: built, model: model, shot: shot) {
            return blockMeanGhost(model, why: "ghost = block mean; " + mismatch, extra: poolNote)
        }
        return FormGhost(model: built, legend: best.legend,
                         provenance: best.legend + ". " + poolNote
                            + " The rule is your own numbers only: accepted shots that crossed inside the make band, released within one SD of your own release speed — no professional's form and no population average is drawn on this screen.",
                         isBestRepGhost: true, unavailableReason: nil)
    }

    private static func blockMeanGhost(_ model: FormModel, why: String, extra: String? = nil) -> FormGhost {
        guard model.isAvailable else {
            return .unavailable(model.unavailableReason ?? "this block has no mean form to ghost")
        }
        let shots = "\(model.shots) accepted shot\(model.shots == 1 ? "" : "s")"
        return FormGhost(model: model, legend: why,
                         provenance: why + ". The ghost is the mean of this block's " + shots + "."
                            + (extra.map { " " + $0 } ?? ""),
                         isBestRepGhost: false, unavailableReason: nil)
    }

    private static func unitMismatch(ghost: FormModel, model: FormModel, shot: ShotForm?) -> String? {
        if let shot, ghost.unit != shot.unit {
            return "your best reps are in \(ghost.unit.rawValue) and this shot is in \(shot.unit.rawValue): a height was given for one and not the other, so they cannot be drawn at the same scale"
        }
        if model.isAvailable, ghost.unit != model.unit {
            return "your best reps are in \(ghost.unit.rawValue) and this block is in \(model.unit.rawValue), so they cannot be drawn at the same scale"
        }
        if let shot, ghost.joints != shot.joints || ghost.sampleCount != shot.sampleCount {
            return "your best reps were built on a different grid from this shot, so they cannot be laid on top of it"
        }
        return nil
    }

    // MARK: Alignment

    /// The translation that puts the ghost's mid-hip on the drawn shot's, at the same instant.
    ///
    /// Both forms already have the mid-hip **at the set point** as their origin, so this only moves
    /// what the shooter's hips did differently *after* the set. With it, the ghost compares shape;
    /// without it, it would also compare where they stood. The legend says which is on screen.
    static func midHipOffset(ghost: [SIMD3<Double>?], ghostJoints: [String],
                             shot: [SIMD3<Double>?], shotJoints: [String]) -> SIMD3<Double> {
        guard let a = midHip(ghost, ghostJoints), let b = midHip(shot, shotJoints) else { return .zero }
        return b - a
    }

    private static func midHip(_ positions: [SIMD3<Double>?], _ joints: [String]) -> SIMD3<Double>? {
        guard let l = FormPhaseStops.point(joints, positions, Body2DPoint.leftHip),
              let r = FormPhaseStops.point(joints, positions, Body2DPoint.rightHip) else { return nil }
        return (l + r) / 2
    }
}
