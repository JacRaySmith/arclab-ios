import Foundation

// ================================================================================================
// MARK: - Basketball IQ trainer: what a scenario is
// ================================================================================================
//
// A scenario is a short play on court coordinates, in metres, that the app renders in 3-D from the
// user's own eye height and freezes mid-action so a read can be chosen. Nothing here touches
// SceneKit, SwiftUI or the network: it is positions, times, options and words, so the interpolation
// can be checked by `IQScenarioLibrary.selfCheck()` the way `CaptureView.geometrySelfCheck` checks
// the preview geometry.
//
// **Honesty about what these are.** Every best read in this file is *coaching convention* — what
// coaches teach, and what the options themselves describe — not a measured result from tracking
// data. None of them is graded above D (`IQScenario.evidenceGrade`), and the trainer screen says
// so. The only numbers the app ever reports back are the ones it measures itself: whether the
// chosen read matched the authored best read, and how long the choice took in milliseconds.

// MARK: - Court

/// Half-court geometry, in metres, origin at the middle of the endline; +z runs into the court,
/// +x runs to the right as you stand on the endline looking in.
///
/// The arc, the free-throw line, the basket set-back and the rim come from the FIBA columns of
/// `docs/reference/sdk-and-licensing-research-2026-09-12.md` §6, which were read from the 2026
/// rulebook and equipment PDFs. Two numbers used for drawing only are **not** in that verified
/// table and are marked as such below: the court's own width, and the width of the lane. They
/// place lines in a picture; no measurement the app reports depends on either.
enum IQCourt {
    /// FIBA playing court is 15 m wide (Official Basketball Rules, Art. 2.1). NOT in the repo's
    /// verified table — drawing only. It is also what makes the corner line land where the verified
    /// table says it does: 0.90 m inside the sideline.
    static let halfWidth = 7.5
    /// Half of the 28 m FIBA court (Art. 2.1). NOT in the repo's verified table — drawing only.
    static let halfLength = 14.0

    /// Basket centre, 1.575 m from the inner edge of the endline (verified table).
    static let basketZ = 1.575
    /// Top of ring, 3.05 m (verified table; `ShotGeometry.Court.rimHeight` is the same number in feet).
    static let rimHeight = 3.05
    static let rimInnerRadius = 0.225
    /// 6.75 m arc from the basket centre (verified table).
    static let threePointRadius = 6.75
    /// Corner line, 0.90 m inside the sideline (verified table) → |x| = 6.60.
    static let cornerLineX = halfWidth - 0.90
    /// Free-throw line, 5.80 m from the inner edge of the endline (verified table).
    static let freeThrowZ = 5.80
    /// FIBA restricted area is 4.90 m wide (Art. 2.4.3). NOT in the repo's verified table — drawing only.
    static let laneHalfWidth = 2.45
    /// Backboard face, 1.20 m from the endline (verified table).
    static let backboardZ = 1.20
    static let backboardWidth = 1.80
    static let backboardHeight = 1.05
    /// Painted line width used for the drawing. Rulebooks put court lines at 5 cm.
    static let lineWidth = 0.05

    /// Where the arc crosses a given x, as a z. Nil when |x| is outside the arc's reach.
    static func arcZ(atX x: Double) -> Double? {
        let r2 = threePointRadius * threePointRadius - x * x
        guard r2 > 0 else { return nil }
        return basketZ + r2.squareRoot()
    }
}

// MARK: - Positions over time

/// One point on a track: a time in seconds from the start of the play, a court position in metres,
/// and an optional height. Height is only ever set for the ball; a player's feet are on the floor.
struct IQWaypoint: Sendable, Equatable {
    var t: Double
    var x: Double
    var z: Double
    var y: Double?

    init(_ t: Double, _ x: Double, _ z: Double, _ y: Double? = nil) {
        self.t = t; self.x = x; self.z = z; self.y = y
    }
}

struct IQPoint: Sendable, Equatable {
    var x: Double
    var z: Double
    var y: Double
}

enum IQSide: Sendable, Equatable {
    case offence, defence
}

/// One player on the floor. `id` is referenced by `IQScenario.cueActorID` and by `IQGaze.actor`.
struct IQActor: Identifiable, Sendable {
    var id: String
    /// What the label above the player says on screen. Short — it has to read at phone size.
    var label: String
    var side: IQSide
    var track: [IQWaypoint]
    /// The player whose eyes the camera sits behind. Exactly one actor per scenario has this.
    var isUser: Bool

    init(_ id: String, _ label: String, _ side: IQSide, user: Bool = false, _ points: [IQWaypoint]) {
        self.id = id; self.label = label; self.side = side; self.track = points; self.isUser = user
    }
}

/// Interpolation between waypoints. Pure, allocation-free, and checked by `IQScenarioLibrary.selfCheck()`.
enum IQPath {
    /// Smoothstep, so players ease in and out of a cut instead of changing velocity in one frame.
    /// `smoothstep(0) = 0`, `smoothstep(1) = 1`, `smoothstep(0.5) = 0.5` — which is why the midpoint
    /// check in the self-check is exact.
    static func smoothstep(_ u: Double) -> Double {
        let c = min(max(u, 0), 1)
        return c * c * (3 - 2 * c)
    }

    /// The position on a track at time `t`, held at the first and last waypoint outside the track's
    /// own span. A track with one waypoint is a player standing still.
    static func position(_ track: [IQWaypoint], at t: Double, defaultHeight: Double = 0) -> IQPoint {
        guard let first = track.first else { return IQPoint(x: 0, z: 0, y: defaultHeight) }
        if track.count == 1 || t <= first.t {
            return IQPoint(x: first.x, z: first.z, y: first.y ?? defaultHeight)
        }
        guard let last = track.last else { return IQPoint(x: first.x, z: first.z, y: first.y ?? defaultHeight) }
        if t >= last.t { return IQPoint(x: last.x, z: last.z, y: last.y ?? defaultHeight) }
        var i = 0
        while i + 1 < track.count && track[i + 1].t < t { i += 1 }
        let a = track[i], b = track[i + 1]
        let span = b.t - a.t
        let u = span > 0 ? smoothstep((t - a.t) / span) : 1
        let ay = a.y ?? defaultHeight, by = b.y ?? defaultHeight
        return IQPoint(x: a.x + (b.x - a.x) * u,
                       z: a.z + (b.z - a.z) * u,
                       y: ay + (by - ay) * u)
    }
}

// MARK: - The read

/// One option the user can tap. Exactly one per scenario is the best read.
struct IQRead: Identifiable, Sendable {
    var id: String
    /// Two or three words on the button.
    var label: String
    /// What that means on the floor, one short line under the label.
    var action: String
    var isBest: Bool

    init(_ id: String, _ label: String, _ action: String, best: Bool = false) {
        self.id = id; self.label = label; self.action = action; self.isBest = best
    }
}

/// Where the camera looks. The user's head does not swivel at random: it points at the basket for a
/// ball handler, at the ball for a defender, or at one named player.
enum IQGaze: Sendable, Equatable {
    case basket
    case ball
    case actor(String)
}

/// What a scenario trains. The progress card groups results by this, because "you read drop
/// coverage well and guess on closeouts" is worth knowing and one overall percentage is not.
enum IQPrinciple: String, Codable, Sendable, CaseIterable {
    case ballHandlerRead
    case screenerRead
    case driveAndKick
    case closeout
    case transition
    case lateClock
    case helpDefence

    var title: String {
        switch self {
        case .ballHandlerRead: return "Pick-and-roll: with the ball"
        case .screenerRead: return "Pick-and-roll: setting the screen"
        case .driveAndKick: return "Drive and kick"
        case .closeout: return "Reading a closeout"
        case .transition: return "Transition"
        case .lateClock: return "Late clock"
        case .helpDefence: return "Help defence"
        }
    }
}

struct IQScenario: Identifiable, Sendable {
    var id: String
    var title: String
    /// "Pick-and-roll, drop coverage" — the setup, said plainly.
    var situation: String
    var principle: IQPrinciple
    var actors: [IQActor]
    var ball: [IQWaypoint]
    /// How long the whole play runs, including what happens after the freeze.
    var duration: Double
    /// The moment the picture stops and the clock on the decision starts.
    var freezeAt: Double
    var gaze: IQGaze
    var reads: [IQRead]
    /// One paragraph, naming the thing on screen that gives it away.
    var why: String
    /// The player the reveal puts a ring under — the cue the paragraph names.
    var cueActorID: String?
    /// Seconds left at the freeze, when the scenario turns on a clock, and which clock it is.
    /// Both nil together: a scenario with no clock pressure shows no clock at all rather than a
    /// number nobody set.
    var clockSeconds: Double?
    var clockLabel: String?
    var source: String
    /// D throughout: these are conventions coaches teach, not measured outcomes. See the file header.
    var evidenceGrade: String

    var user: IQActor? { actors.first(where: { $0.isUser }) }
    var bestRead: IQRead? { reads.first(where: { $0.isBest }) }

    /// Every player's position at `t`, in the order the actors were authored.
    func snapshot(at t: Double) -> IQFrame {
        IQFrame(t: t,
                actors: actors.map {
                    IQActorSnapshot(id: $0.id, label: $0.label, side: $0.side, isUser: $0.isUser,
                                    point: IQPath.position($0.track, at: t))
                },
                ball: IQPath.position(ball, at: t, defaultHeight: 1.0))
    }

    /// Where the camera looks at `t`, as a court point. Height is chest height for a player, the
    /// ball's own height for the ball, and the ring for the basket.
    func gazeTarget(at t: Double) -> IQPoint {
        switch gaze {
        case .basket:
            // Aimed at the body height under the ring, not at the ring itself: a camera pointed
            // up at the rim spends half the picture on the ceiling.
            return IQPoint(x: 0, z: IQCourt.basketZ, y: 1.8)
        case .ball:
            var p = IQPath.position(ball, at: t, defaultHeight: 1.0)
            p.y = max(p.y, 1.0)
            return p
        case .actor(let id):
            guard let a = actors.first(where: { $0.id == id }) else {
                return IQPoint(x: 0, z: IQCourt.basketZ, y: 1.8)
            }
            var p = IQPath.position(a.track, at: t)
            p.y = 1.35
            return p
        }
    }
}

// MARK: - Where the camera goes

/// The first-person camera, in one place, because two things depend on agreeing about it: the
/// scene that renders the play, and the self-check that refuses to ship a scenario whose cue is
/// off the side of the picture.
enum IQCamera {
    /// Eye height for the player whose eyes we are behind.
    static let eyeHeight = 1.70
    /// The eye is set back this far along its own sight line. True first person puts the lens
    /// inside the chest of any defender standing a metre away; half a metre of set-back keeps the
    /// same view and the same height without a red capsule filling the screen.
    static let setBack = 0.60
    /// Wide, because a player's useful field is far wider than a film lens. SceneKit is told to
    /// apply this across the width of the picture.
    static let horizontalFieldOfViewDegrees = 96.0
    static var halfFieldOfViewDegrees: Double { horizontalFieldOfViewDegrees / 2 }
    /// How close another player may be to the user at the freeze. Closer than this and the picture
    /// is a jersey.
    static let minimumClearance = 0.95
    /// Looking at something nearer than this has no stable answer: the sight line stands up and the
    /// camera rolls. The scene falls back to the basket.
    static let minimumGazeDistance = 1.2
}

extension IQScenario {
    /// Where the camera sits and what it is pointed at, at time `t`. `override` is the reveal's
    /// pan target: the player's head turning towards the cue once the answer has been given.
    func cameraPlacement(at t: Double, lookingAt override: IQPoint? = nil) -> (eye: IQPoint, target: IQPoint) {
        let u = user.map { IQPath.position($0.track, at: t) } ?? IQPoint(x: 0, z: 9, y: 0)
        var target = override ?? gazeTarget(at: t)
        var dx = target.x - u.x, dz = target.z - u.z
        var distance = (dx * dx + dz * dz).squareRoot()
        if distance < IQCamera.minimumGazeDistance {
            target = IQPoint(x: 0, z: IQCourt.basketZ, y: 1.8)
            dx = target.x - u.x; dz = target.z - u.z
            distance = (dx * dx + dz * dz).squareRoot()
        }
        guard distance > 0.001 else {
            return (IQPoint(x: u.x, z: u.z, y: IQCamera.eyeHeight), target)
        }
        let eye = IQPoint(x: u.x - dx / distance * IQCamera.setBack,
                          z: u.z - dz / distance * IQCamera.setBack,
                          y: IQCamera.eyeHeight)
        return (eye, target)
    }

    /// How far off the centre of the picture something is, in degrees; positive to the right.
    /// Anything beyond half the field of view is not on screen.
    func bearingDegrees(to p: IQPoint, at t: Double) -> Double {
        let (eye, target) = cameraPlacement(at: t)
        let forward = atan2(target.x - eye.x, target.z - eye.z)
        var delta = atan2(p.x - eye.x, p.z - eye.z) - forward
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        return delta * 180 / .pi
    }

    /// The distance from the user's own feet, which is what "somebody is standing in the lens"
    /// means — measured from the player, not from the set-back camera.
    func distanceFromUser(to p: IQPoint, at t: Double) -> Double {
        guard let user else { return .infinity }
        let u = IQPath.position(user.track, at: t)
        return ((p.x - u.x) * (p.x - u.x) + (p.z - u.z) * (p.z - u.z)).squareRoot()
    }
}

struct IQActorSnapshot: Sendable, Identifiable {
    var id: String
    var label: String
    var side: IQSide
    var isUser: Bool
    var point: IQPoint
}

struct IQFrame: Sendable {
    var t: Double
    var actors: [IQActorSnapshot]
    var ball: IQPoint
}
