import Foundation
import ShotGeometry
import simd

// ================================================================================================
// MARK: - The stops on the shot clock
// ================================================================================================
//
// 1.2 item 18: the form screens open on the release and a segmented control jumps the clock. The
// Sportsbox pattern set names six stops — load, dip, set, rise, release, follow — and this app times
// **four** of them: `FormPhase` is set, dip, release and follow-through, and those four are the only
// instants the pipeline ever puts a time on.
//
// So the other two are built here, from the shot's own samples, and are marked as what they are:
//
//   · **Load**  — the instant of the shooter's *smallest knee angle* before the release.
//   · **Rise**  — the instant the wrist first passes *halfway* from its lowest point to where it is
//     at the release.
//
// Both are positions on samples that are already on screen — an argmin and a halfway crossing — not
// new measurements and not named events the model detects; `provenance` says so, and a stop that
// cannot be formed carries the reason instead of a time. Nothing here invents a phase boundary.

struct FormClockStop: Identifiable, Sendable, Equatable {
    var key: String
    var label: String
    /// Normalised τ, or seconds on the file's real clock — whichever builder made it.
    var time: Double?
    var unavailableReason: String?
    /// True for load and rise: derived from the samples, not timed by the model.
    var isDerived: Bool
    var provenance: String

    var id: String { key }
    var isAvailable: Bool { time != nil }
}

enum FormPhaseStops {

    static let loadProvenance = "load = the sample with the smallest knee angle before the release. It is an argmin over the samples on this screen, not an event the model times."
    static let riseProvenance = "rise = the first sample where the wrist has climbed halfway from its lowest point to where it is at the release. It is a position on the samples on this screen, not an event the model times."

    /// The six stops on the **normalised** clock, from whatever skeleton the screen is drawing.
    /// `samples` must be in τ order.
    static func normalised(joints: [String],
                           samples: [(t: Double, positions: [SIMD3<Double>?])]) -> [FormClockStop] {
        var stops: [FormClockStop] = FormPhase.allCases.map {
            FormClockStop(key: $0.rawValue, label: shortLabel($0), time: $0.normalisedTime,
                          unavailableReason: nil, isDerived: false,
                          provenance: "\(shortLabel($0).lowercased()) = \($0.label.lowercased()), at τ \(String(format: "%.2f", $0.normalisedTime)) on the phase-normalised clock the form was built on.")
        }
        let release = FormPhase.release.normalisedTime, dip = FormPhase.dip.normalisedTime

        // ---- load: the smallest knee angle before the release ----
        let knees = samples.map { s in (t: s.t, value: meanKneeAngle(joints: joints, positions: s.positions)) }
            .filter { $0.t <= release + 1e-9 }
        let load: FormClockStop
        if let best = knees.compactMap({ p -> (Double, Double)? in p.value.map { (p.t, $0) } }).min(by: { $0.1 < $1.1 }) {
            load = FormClockStop(key: "load", label: "Load", time: best.0, unavailableReason: nil,
                                 isDerived: true, provenance: loadProvenance)
        } else {
            load = FormClockStop(key: "load", label: "Load", time: nil,
                                 unavailableReason: "no sample before the release has a hip, a knee and an ankle on the same side, so there is no knee angle to take the deepest of",
                                 isDerived: true, provenance: loadProvenance)
        }

        // ---- rise: halfway up from the lowest wrist to the wrist at the release ----
        let climb = samples.filter { $0.t >= dip - 1e-9 && $0.t <= release + 1e-9 }
            .compactMap { s -> (t: Double, z: Double)? in
                wristHeight(joints: joints, positions: s.positions).map { (s.t, $0) }
            }
        let rise = halfwayStop(climb)
        stops.append(contentsOf: [load, rise])
        return ordered(stops, conventional: ["set": 0.0, "load": dip - 1e-3, "dip": dip,
                                             "rise": (dip + release) / 2, "release": release, "followThrough": 1.0])
    }

    /// The six stops on a `BodyShot`'s **real** clock, in seconds.
    static func real(shot: BodyShot, playback: BodyShotPlayback) -> [FormClockStop] {
        var stops: [FormClockStop] = playback.phases.map { p in
            FormClockStop(key: key(forPhaseName: p.name), label: shortLabel(named: p.name), time: p.realTime,
                          unavailableReason: p.unavailableReason, isDerived: false,
                          provenance: "\(p.name.lowercased()) = the instant this file's own timing found, on its real clock.")
        }
        let release = playback.releaseRealTime
        let dipTime = stops.first { $0.key == "dip" }?.time

        // ---- load: the smallest knee angle this file measured before the release ----
        let kneeSamples = ["kneeRight", "kneeLeft"].compactMap { shot.angles[$0] }
            .flatMap { $0.samples }.filter { $0.t_real <= release }
        let load: FormClockStop
        if let best = kneeSamples.min(by: { $0.radians < $1.radians }) {
            load = FormClockStop(key: "load", label: "Load", time: best.t_real, unavailableReason: nil,
                                 isDerived: true, provenance: loadProvenance)
        } else {
            load = FormClockStop(key: "load", label: "Load", time: nil,
                                 unavailableReason: shot.angles["kneeRight"]?.unavailableReason
                                    ?? "this file carries no knee angle before the release, so there is no deepest one to jump to",
                                 isDerived: true, provenance: loadProvenance)
        }

        // ---- rise: halfway up from the lowest wrist to the wrist at the release ----
        let wrist = (shot.shootingSide ?? "right") == "left" ? "leftWrist" : "rightWrist"
        let from = dipTime ?? playback.first
        let climb = shot.frames
            .filter { $0.t_real >= from - 1e-9 && $0.t_real <= release + 1e-9 }
            .compactMap { f -> (t: Double, z: Double)? in f.fitted3D[wrist].map { (f.t_real, $0.z) } }
        var rise = halfwayStop(climb, what: "the \(wrist)")
        if rise.isAvailable, dipTime == nil {
            rise.provenance += " This file has no dip, so the climb was measured from its first frame."
        }
        stops.append(contentsOf: [load, rise])
        return ordered(stops, conventional: ["set": playback.first, "load": release - 0.4, "dip": release - 0.3,
                                             "rise": release - 0.1, "release": release, "followThrough": playback.last])
    }

    // MARK: Helpers

    /// The first sample at which the wrist has climbed halfway from its lowest point to where it is
    /// at the end of the window — the last sample, which is the release on both clocks.
    ///
    /// Halfway is a stated convention, not a measurement, and `riseProvenance` says so. It is used
    /// instead of the fastest climb because on a real shot the wrist is still accelerating at the
    /// release, so "fastest" lands on the release itself and the stop would be a duplicate.
    private static func halfwayStop(_ climb: [(t: Double, z: Double)],
                                    what: String = "a wrist") -> FormClockStop {
        guard let low = climb.map(\.z).min(), let top = climb.last?.z, top > low + 1e-9 else {
            return FormClockStop(key: "rise", label: "Rise", time: nil,
                                 unavailableReason: climb.isEmpty
                                    ? "no sample between the dip and the release carries \(what), so there is no climb to find the middle of"
                                    : "the wrist does not climb between the dip and the release on this shot, so there is no halfway point",
                                 isDerived: true, provenance: riseProvenance)
        }
        let half = (low + top) / 2
        guard let first = climb.first(where: { $0.z >= half }) else {
            return FormClockStop(key: "rise", label: "Rise", time: nil,
                                 unavailableReason: "no sample reaches halfway up the climb",
                                 isDerived: true, provenance: riseProvenance)
        }
        return FormClockStop(key: "rise", label: "Rise", time: first.t, unavailableReason: nil,
                             isDerived: true, provenance: riseProvenance)
    }

    /// In clock order, so the control never claims a sequence the times contradict. A stop with no
    /// time keeps its conventional place.
    private static func ordered(_ stops: [FormClockStop], conventional: [String: Double]) -> [FormClockStop] {
        stops.enumerated().sorted { a, b in
            let ka = a.element.time ?? conventional[a.element.key] ?? 0
            let kb = b.element.time ?? conventional[b.element.key] ?? 0
            return ka == kb ? a.offset < b.offset : ka < kb
        }.map(\.element)
    }

    private static func shortLabel(_ p: FormPhase) -> String {
        p == .followThrough ? "Follow" : p.label
    }
    private static func shortLabel(named name: String) -> String {
        name == "Follow-through" ? "Follow" : name
    }
    private static func key(forPhaseName name: String) -> String {
        switch name {
        case "Set": return "set"
        case "Dip": return "dip"
        case "Release": return "release"
        default: return "followThrough"
        }
    }

    /// The mean of whichever knee angles this sample can form, radians. Nil when neither leg has all
    /// three of hip, knee and ankle.
    static func meanKneeAngle(joints: [String], positions: [SIMD3<Double>?]) -> Double? {
        let sides = [(Body2DPoint.leftHip, Body2DPoint.leftKnee, Body2DPoint.leftAnkle),
                     (Body2DPoint.rightHip, Body2DPoint.rightKnee, Body2DPoint.rightAnkle)]
        let angles = sides.compactMap { s -> Double? in
            guard let h = point(joints, positions, s.0), let k = point(joints, positions, s.1),
                  let a = point(joints, positions, s.2) else { return nil }
            return angle(h, k, a)
        }
        return angles.isEmpty ? nil : angles.reduce(0, +) / Double(angles.count)
    }

    /// The higher of whichever wrists this sample carries, in the body frame's up axis (z).
    static func wristHeight(joints: [String], positions: [SIMD3<Double>?]) -> Double? {
        [Body2DPoint.leftWrist, Body2DPoint.rightWrist]
            .compactMap { point(joints, positions, $0)?.z }.max()
    }

    static func point(_ joints: [String], _ positions: [SIMD3<Double>?], _ name: String) -> SIMD3<Double>? {
        guard let i = joints.firstIndex(of: name), i < positions.count else { return nil }
        return positions[i]
    }

    /// The angle at `v`, radians. Nil on a degenerate limb.
    static func angle(_ a: SIMD3<Double>, _ v: SIMD3<Double>, _ b: SIMD3<Double>) -> Double? {
        let u = a - v, w = b - v
        let lu = simd_length(u), lw = simd_length(w)
        guard lu > 1e-9, lw > 1e-9 else { return nil }
        return acos(min(1, max(-1, simd_dot(u, w) / (lu * lw))))
    }
}
