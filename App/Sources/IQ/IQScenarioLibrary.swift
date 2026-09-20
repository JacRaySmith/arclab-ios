import Foundation

// ================================================================================================
// MARK: - The plays
// ================================================================================================
//
// Twenty-four scenarios, authored as court coordinates in metres. Read the header of
// `IQScenario.swift` first: every "best read" here is coaching convention, graded D, and the app
// says so on the reveal. What the app measures — right or wrong against the authored answer, and
// how long the choice took — is its own number and is reported with an n.
//
// The floor is laid out for a right-hand middle pick-and-roll: the ball starts in the right slot,
// the screen is set on the ball handler's inside shoulder, and the other three attackers hold the
// left wing and both corners. Keeping the spacing the same across the pick-and-roll scenarios is
// deliberate — the only thing that changes between them is what the two defenders in the action do,
// which is exactly the thing the user is being asked to read.

// MARK: - Authoring helpers

/// A player who does not move.
private func at(_ x: Double, _ z: Double) -> [IQWaypoint] { [IQWaypoint(0, x, z)] }

/// A track: (seconds, x, z) …
private func path(_ v: (Double, Double, Double)...) -> [IQWaypoint] {
    v.map { IQWaypoint($0.0, $0.1, $0.2) }
}

/// A ball flight: (seconds, x, z, height) …
private func flight(_ v: (Double, Double, Double, Double)...) -> [IQWaypoint] {
    v.map { IQWaypoint($0.0, $0.1, $0.2, $0.3) }
}

/// A ball that rides in a player's hands until `until`, then does whatever `then` says. Saves
/// authoring the same positions twice and keeps the ball exactly where the player is.
private func ballWith(_ track: [IQWaypoint], until: Double, then: [IQWaypoint] = []) -> [IQWaypoint] {
    var out: [IQWaypoint] = []
    for w in track where w.t < until { out.append(IQWaypoint(w.t, w.x + 0.24, w.z, 1.0)) }
    let p = IQPath.position(track, at: until)
    out.append(IQWaypoint(until, p.x + 0.24, p.z, 1.0))
    out.append(contentsOf: then)
    return out
}

/// The three attackers who are not in the pick-and-roll and the three defenders on them.
/// Labels are overridable because in one scenario the left-corner defender is "the low man" and in
/// another he is just a man in the corner, and the label is part of what the user reads.
private func spacers(leftCornerD: String = "Weak side", leftCornerDTrack: [IQWaypoint]? = nil,
                     rightCornerD: String = "Corner D", rightCornerDTrack: [IQWaypoint]? = nil,
                     leftWingD: String = "Wing D", leftWingDTrack: [IQWaypoint]? = nil) -> [IQActor] {
    [
        IQActor("rc", "Corner", .offence, at(6.6, 1.6)),
        IQActor("lc", "Corner", .offence, at(-6.6, 1.6)),
        IQActor("lw", "Wing", .offence, at(-5.0, 6.1)),
        IQActor("drc", rightCornerD, .defence, rightCornerDTrack ?? at(5.9, 2.3)),
        IQActor("dlc", leftCornerD, .defence, leftCornerDTrack ?? at(-5.9, 2.3)),
        IQActor("dlw", leftWingD, .defence, leftWingDTrack ?? at(-4.3, 5.6)),
    ]
}

/// The four players in a pick-and-roll, in the order the scene draws them.
private func pnr(handler: [IQWaypoint], screener: [IQWaypoint], onBall: [IQWaypoint], big: [IQWaypoint],
                 handlerIsUser: Bool = true, bigLabel: String = "Their big",
                 onBallLabel: String = "Your man", screenerLabel: String = "Screener") -> [IQActor] {
    [
        IQActor("user", handlerIsUser ? "You" : "Ball", .offence, user: handlerIsUser, handler),
        IQActor("big", handlerIsUser ? screenerLabel : "You", .offence, user: !handlerIsUser, screener),
        IQActor("d1", onBallLabel, .defence, onBall),
        IQActor("d5", bigLabel, .defence, big),
    ]
}

private let conventionSource = "Coaching convention — what coaches teach for this coverage. Not a measured result."

// MARK: - The library

enum IQScenarioLibrary {
    static let all: [IQScenario] = [
        dropPullUp(), dropUnder(), hedgePocket(), blitzOutlet(), switchAttack(),
        iceReject(), snakeBack(), lobOverTheTop(),
        rollIntoPocket(), popAgainstHedge(),
        driveBaselineLowMan(), driveMiddleNoHelp(), driveTagger(), driveSkipWeak(),
        closeoutLate(), closeoutFlying(), closeoutOnTime(),
        twoOnOneBallStopped(), twoOnOneRunnerCovered(), threeOnTwo(),
        lateClockFive(), downThreeEightSeconds(),
        helpLowManSteps(), helpStayHome(),
    ]

    static func scenario(id: String) -> IQScenario? { all.first { $0.id == id } }

    /// A session: eight plays, one per principle where there is one, then filled out at random, so
    /// a session is never eight pick-and-rolls in a row.
    static func session(count: Int = 8, using generator: inout SystemRandomNumberGenerator) -> [IQScenario] {
        var byPrinciple: [IQPrinciple: [IQScenario]] = [:]
        for s in all { byPrinciple[s.principle, default: []].append(s) }
        var picked: [IQScenario] = []
        for principle in IQPrinciple.allCases {
            if let one = byPrinciple[principle]?.randomElement(using: &generator) { picked.append(one) }
        }
        picked.shuffle(using: &generator)
        if picked.count > count { picked = Array(picked.prefix(count)) }
        let rest = all.filter { s in !picked.contains(where: { $0.id == s.id }) }.shuffled(using: &generator)
        picked.append(contentsOf: rest.prefix(max(0, count - picked.count)))
        return picked.shuffled(using: &generator)
    }
}

// MARK: - Pick-and-roll: with the ball

/// 1. Drop coverage that never comes up: the shot in front of the big is the one on offer.
private func dropPullUp() -> IQScenario {
    let handler = path((0, 3.4, 9.8), (1.0, 2.9, 9.0), (2.0, 1.7, 8.4), (2.6, 0.5, 6.9), (3.6, 0.4, 6.7), (5.2, 0.4, 6.7))
    let screener = path((0, -0.6, 6.6), (0.9, 1.6, 8.6), (2.0, 1.7, 8.5), (2.6, 1.7, 7.6), (3.6, 0.9, 4.4), (5.2, 0.5, 3.0))
    let onBall = path((0, 3.1, 9.0), (1.0, 2.6, 8.3), (2.0, 2.3, 8.1), (2.6, 1.6, 7.5), (3.6, 0.8, 6.9), (5.2, 0.7, 6.8))
    let big = path((0, 0.4, 5.8), (1.0, 1.2, 6.6), (2.0, 1.0, 5.6), (2.6, 0.5, 4.8), (3.6, 0.4, 4.4), (5.2, 0.3, 4.2))
    return IQScenario(
        id: "pnr-drop-pullup", title: "The big stays home",
        situation: "Pick-and-roll at the top. Their big is in drop coverage.",
        principle: .ballHandlerRead,
        actors: pnr(handler: handler, screener: screener, onBall: onBall, big: big) + spacers(),
        ball: ballWith(handler, until: 3.0,
                       then: flight((3.7, 0.4, 5.6, 3.9), (4.4, 0.2, 3.4, 4.5), (5.2, 0.0, 1.6, 3.05))),
        duration: 5.2, freezeAt: 2.6, gaze: .basket,
        reads: [
            IQRead("pull", "Pull up", "Rise into the shot in front of the big", best: true),
            IQRead("lob", "Throw the lob", "Float it over the big to the roller"),
            IQRead("corner", "Kick to the corner", "Swing it out to the near corner"),
            IQRead("reset", "Keep your dribble", "Back it out and run it again"),
        ],
        why: """
        Look at the big's feet: when you turn the corner he is still level with the free-throw line \
        and backing up. That is drop coverage doing its job — it takes away the rim and it takes \
        away the lob, and in exchange it gives you the shot in front of it. Your own man is a step \
        behind your hip, so nobody is close enough to contest. The shot the defence chose to give \
        you is the shot to take, and taking it is also what makes them stop playing drop.
        """,
        cueActorID: "d5", clockSeconds: nil, clockLabel: nil,
        source: conventionSource, evidenceGrade: "D")
}

/// 2. Under the screen: the three is the punishment.
private func dropUnder() -> IQScenario {
    let handler = path((0, 3.4, 9.8), (1.0, 2.9, 9.0), (2.2, 0.9, 8.8), (3.0, 0.8, 8.8), (4.8, 0.8, 8.8))
    let screener = path((0, -0.6, 6.6), (0.9, 1.6, 8.6), (2.2, 1.9, 8.4), (3.2, 1.2, 5.6), (4.8, 0.8, 3.4))
    let onBall = path((0, 3.1, 9.0), (1.0, 2.6, 8.3), (2.0, 1.4, 7.5), (2.8, 1.4, 8.0), (4.8, 1.4, 8.4))
    let big = path((0, 0.4, 5.8), (1.0, 1.0, 6.2), (2.2, 0.9, 5.6), (3.2, 0.6, 4.6), (4.8, 0.4, 4.0))
    return IQScenario(
        id: "pnr-drop-under", title: "They go under it",
        situation: "Pick-and-roll at the top. Your man cuts under the screen.",
        principle: .ballHandlerRead,
        actors: pnr(handler: handler, screener: screener, onBall: onBall, big: big) + spacers(),
        ball: ballWith(handler, until: 2.9,
                       then: flight((3.5, 0.7, 6.8, 4.0), (4.2, 0.4, 4.0, 4.6), (4.8, 0.2, 1.7, 3.05))),
        duration: 4.8, freezeAt: 2.2, gaze: .basket,
        reads: [
            IQRead("three", "Shoot the three", "Step into it behind the screen", best: true),
            IQRead("drive", "Drive it", "Put the ball down and go at the big"),
            IQRead("roller", "Pass to the roller", "Feed the big rolling to the rim"),
            IQRead("rescreen", "Ask for another screen", "Wave the big back for a re-screen"),
        ],
        why: """
        Your man's head comes out on the wrong side of the screen — he went under it, so for one \
        beat he is below the ball and you are behind the arc with nobody within a metre. Going \
        under is a defence saying "we do not think you will shoot this". The three is the open \
        shot, and it is worth more than the drive you would take into a big who is already set.
        """,
        cueActorID: "d1", clockSeconds: nil, clockLabel: nil,
        source: conventionSource, evidenceGrade: "D")
}

/// 3. Hard hedge: the pocket pass turns it into four on three.
private func hedgePocket() -> IQScenario {
    let handler = path((0, 3.4, 9.8), (1.0, 2.9, 9.0), (2.0, 1.8, 8.6), (2.6, 1.1, 8.9), (3.4, 1.2, 9.1), (5.0, 1.3, 9.2))
    let screener = path((0, -0.6, 6.6), (0.9, 1.6, 8.6), (2.2, 1.4, 7.6), (3.2, 1.0, 6.2), (5.0, 0.8, 5.4))
    let onBall = path((0, 3.1, 9.0), (1.0, 2.6, 8.3), (2.0, 2.4, 8.2), (2.6, 2.1, 8.6), (3.4, 1.7, 8.9), (5.0, 1.6, 9.0))
    let big = path((0, 0.6, 6.0), (1.0, 1.4, 7.6), (2.4, 0.5, 8.2), (3.4, 0.6, 7.4), (5.0, 0.7, 6.4))
    return IQScenario(
        id: "pnr-hedge-pocket", title: "The big shows hard",
        situation: "Pick-and-roll at the top. Their big jumps out at you.",
        principle: .ballHandlerRead,
        actors: pnr(handler: handler, screener: screener, onBall: onBall, big: big, bigLabel: "Hedging big")
            + spacers(),
        ball: ballWith(handler, until: 2.9, then: flight((3.3, 1.0, 6.4, 1.0), (5.0, 0.8, 5.4, 1.0))),
        duration: 5.0, freezeAt: 2.4, gaze: .basket,
        reads: [
            IQRead("pocket", "Pocket pass", "Low bounce pass into the space the big left", best: true),
            IQRead("split", "Split them", "Dribble between the two defenders"),
            IQRead("retreat", "Back it out", "Retreat dribble and start over"),
            IQRead("over", "Shoot over the hedge", "Rise up against the big's contest"),
        ],
        why: """
        Both of their feet are outside the arc — the big is at your chest and your own man is \
        behind him, so two defenders are guarding one ball. Everything the big was guarding is now \
        behind his back. The pocket pass is the short, low one into that gap, and the moment the \
        screener catches it there are four of you against three of them. Splitting is the highlight \
        play, but it is the one they are standing there hoping you try.
        """,
        cueActorID: "d5", clockSeconds: nil, clockLabel: nil,
        source: conventionSource, evidenceGrade: "D")
}

/// 4. Blitz: get off it before the trap closes.
private func blitzOutlet() -> IQScenario {
    let handler = path((0, 3.4, 9.8), (1.0, 2.9, 9.2), (2.2, 2.0, 9.1), (2.6, 2.0, 9.2), (4.8, 2.1, 9.3))
    let screener = path((0, -0.6, 6.6), (0.9, 1.6, 8.6), (2.2, 0.9, 7.6), (2.8, 0.6, 6.8), (4.8, 0.4, 6.2))
    let onBall = path((0, 3.1, 9.0), (1.0, 2.7, 8.7), (2.2, 2.6, 8.2), (3.0, 2.6, 8.6), (4.8, 2.6, 8.8))
    let big = path((0, 0.4, 5.8), (1.0, 1.4, 7.4), (2.2, 1.3, 8.2), (3.0, 1.2, 8.4), (4.8, 1.1, 8.2))
    return IQScenario(
        id: "pnr-blitz-outlet", title: "Two bodies on the ball",
        situation: "Pick-and-roll at the top. They blitz: both defenders come at you.",
        principle: .ballHandlerRead,
        actors: pnr(handler: handler, screener: screener, onBall: onBall, big: big, bigLabel: "Second trapper")
            + spacers(),
        ball: ballWith(handler, until: 2.5, then: flight((2.9, 0.7, 7.0, 1.2), (4.8, 0.4, 6.2, 1.0))),
        duration: 4.8, freezeAt: 2.2, gaze: .basket,
        reads: [
            IQRead("out", "Pass out now", "Hit the screener before the trap shuts", best: true),
            IQRead("split", "Split the trap", "Dribble through the gap between them"),
            IQRead("dribble", "Dribble out of it", "Beat them off the bounce to the sideline"),
            IQRead("hold", "Hold and wait", "Keep your dribble until someone gets open"),
        ],
        why: """
        Both defenders have their hips turned towards you and the gap between them is already \
        shutting — a trap you are still inside in one second is a turnover. The screener is \
        slipping into the space they both left. A blitz can only work if the ball stays put, so \
        the answer is speed, not skill: get rid of it early and let four attackers play against \
        the three defenders who are left.
        """,
        cueActorID: "d5", clockSeconds: nil, clockLabel: nil,
        source: conventionSource, evidenceGrade: "D")
}

/// 5. Switch: attack the new man before help arrives.
private func switchAttack() -> IQScenario {
    let handler = path((0, 3.4, 9.8), (1.0, 2.9, 9.0), (2.0, 1.8, 8.7), (2.6, 0.9, 8.6), (3.6, 0.3, 6.6), (5.0, 0.1, 4.2))
    let screener = path((0, -0.6, 6.6), (0.9, 1.6, 8.6), (2.2, 2.4, 8.8), (3.6, 3.6, 8.0), (5.0, 4.4, 7.2))
    let onBall = path((0, 3.1, 9.0), (1.0, 2.6, 8.3), (2.2, 2.6, 8.4), (3.6, 3.4, 7.4), (5.0, 4.2, 6.7))
    let big = path((0, 0.4, 5.8), (1.0, 1.3, 7.2), (2.0, 1.2, 7.9), (2.6, 0.9, 7.5), (3.6, 0.5, 6.0), (5.0, 0.3, 3.8))
    return IQScenario(
        id: "pnr-switch-attack", title: "They switch it",
        situation: "Pick-and-roll at the top. They switch — the big picks you up.",
        principle: .ballHandlerRead,
        actors: pnr(handler: handler, screener: screener, onBall: onBall, big: big, bigLabel: "Switched onto you")
            + spacers(),
        ball: ballWith(handler, until: 4.2, then: flight((4.6, 0.2, 2.8, 1.4), (5.0, 0.1, 1.8, 3.05))),
        duration: 5.0, freezeAt: 2.6, gaze: .basket,
        reads: [
            IQRead("attack", "Go at him now", "First step, straight past the big", best: true),
            IQRead("wait", "Wave everyone out", "Clear the side and size him up"),
            IQRead("corner", "Pass to the corner", "Give it up and cut away"),
            IQRead("post", "Post your big up", "Throw it in to the mismatch inside"),
        ],
        why: """
        Two things on screen say go now. The big who picked you up is still moving sideways with \
        his weight on his back foot, and both weak-side defenders are standing next to their own \
        men — nobody is in the gap yet. Every second you spend sizing him up is a second the help \
        uses to get where it needs to be. Attacking a switch is a race against the rotation, not \
        a one-on-one contest.
        """,
        cueActorID: "d5", clockSeconds: nil, clockLabel: nil,
        source: conventionSource, evidenceGrade: "D")
}

/// 6. Ice: the screen is a trap, so refuse it.
private func iceReject() -> IQScenario {
    let handler = path((0, 5.4, 8.6), (1.0, 5.0, 8.0), (1.8, 4.6, 7.8), (2.4, 3.4, 6.8), (3.4, 1.8, 5.0), (4.8, 0.7, 3.0))
    let screener = path((0, 5.6, 10.0), (0.9, 4.8, 9.0), (2.4, 4.6, 8.8), (3.4, 4.0, 7.0), (4.8, 3.2, 5.0))
    let onBall = path((0, 5.0, 9.2), (1.0, 5.0, 8.9), (1.8, 5.1, 8.8), (2.4, 4.4, 7.6), (3.4, 2.9, 5.8), (4.8, 1.6, 3.8))
    let big = path((0, 2.6, 4.4), (1.0, 2.6, 5.0), (1.8, 2.5, 5.4), (2.4, 2.2, 5.2), (3.4, 1.4, 4.2), (4.8, 0.9, 3.4))
    return IQScenario(
        id: "pnr-ice-reject", title: "They ice the side screen",
        situation: "Side pick-and-roll. Your man jumps above the screen to force you down the line.",
        principle: .ballHandlerRead,
        actors: pnr(handler: handler, screener: screener, onBall: onBall, big: big,
                    bigLabel: "Waiting at the elbow", onBallLabel: "Top foot up")
            + spacers(rightCornerD: "Corner D"),
        ball: ballWith(handler, until: 4.2, then: flight((4.5, 0.5, 2.4, 1.6), (4.8, 0.2, 1.7, 3.05))),
        duration: 4.8, freezeAt: 2.0, gaze: .basket,
        reads: [
            IQRead("reject", "Refuse the screen", "Cross back and attack the middle", best: true),
            IQRead("use", "Use it anyway", "Come off the screen down the sideline"),
            IQRead("corner", "Pass to the corner", "Give it up and screen away"),
            IQRead("out", "Back it out", "Take the dribble back to the top"),
        ],
        why: """
        The big has parked at the elbow and has not come out past it — that is the tell for ice. \
        Behind you, your own man has jumped to your top shoulder to push you down the sideline, \
        into the corner where the big is waiting and where the line works as an extra defender. \
        A defender leaning that far to one side has nothing behind his other shoulder. Refusing \
        the screen — one hard crossover back to the middle — takes you into the wide part of the \
        floor, and that elbow big is the only one left to beat.
        """,
        cueActorID: "d5", clockSeconds: nil, clockLabel: nil,
        source: conventionSource, evidenceGrade: "D")
}

/// 7. Chased over the top: snake back to the middle.
private func snakeBack() -> IQScenario {
    let handler = path((0, 3.4, 9.8), (1.0, 2.9, 9.0), (2.0, 1.4, 8.6), (2.6, 0.2, 8.0), (3.6, 1.4, 6.6), (5.0, 1.6, 5.2))
    let screener = path((0, -0.6, 6.6), (0.9, 1.6, 8.6), (2.2, 1.8, 8.4), (3.6, 1.6, 5.4), (5.0, 1.0, 3.2))
    let onBall = path((0, 3.1, 9.0), (1.0, 2.6, 8.3), (2.0, 1.9, 9.0), (2.6, 0.7, 9.0), (3.6, -0.4, 7.8), (5.0, 0.2, 6.4))
    let big = path((0, 0.4, 5.8), (1.0, 0.8, 7.0), (2.0, 0.4, 6.8), (2.6, 0.0, 6.6), (3.6, 0.4, 6.0), (5.0, 0.9, 4.6))
    return IQScenario(
        id: "pnr-snake", title: "He chases over the top",
        situation: "Pick-and-roll at the top. Your man fights over the screen and their big is up at the level.",
        principle: .ballHandlerRead,
        actors: pnr(handler: handler, screener: screener, onBall: onBall, big: big, bigLabel: "Up at the level")
            + spacers(),
        ball: ballWith(handler, until: 4.4, then: flight((4.7, 1.6, 4.4, 1.6), (5.0, 1.2, 3.4, 1.4))),
        duration: 5.0, freezeAt: 2.6, gaze: .basket,
        reads: [
            IQRead("snake", "Snake it back", "Cross back across the screen into the middle", best: true),
            IQRead("sideline", "Keep going", "Drive on down the side you started on"),
            IQRead("pickup", "Pick it up and pass", "Stop the dribble and find someone"),
            IQRead("stepback", "Step back and shoot", "Retreat into a three"),
        ],
        why: """
        The big has come all the way up to the level of the screen, so the lane straight ahead is \
        shut. Behind your shoulder your own man is running so hard over the top that he has gone \
        past you, with his momentum still carrying him that way. Snaking means one crossover back \
        across the screen: your body ends up between him and the ball, you are heading back to the \
        middle where the big has just left, and he has to start again from behind.
        """,
        cueActorID: "d5", clockSeconds: nil, clockLabel: nil,
        source: conventionSource, evidenceGrade: "D")
}

/// 8. Nobody tags: throw the lob.
private func lobOverTheTop() -> IQScenario {
    let handler = path((0, 3.4, 9.8), (1.0, 2.9, 9.0), (2.0, 1.7, 8.5), (2.6, 0.8, 7.7), (3.4, 0.6, 7.4), (5.2, 0.6, 7.3))
    let screener = path((0, -0.6, 6.6), (0.9, 1.6, 8.6), (2.0, 1.6, 8.4), (2.6, 0.9, 5.4), (3.6, 0.5, 3.2), (5.2, 0.2, 2.0))
    let onBall = path((0, 3.1, 9.0), (1.0, 2.6, 8.3), (2.0, 2.5, 8.3), (2.6, 1.9, 8.1), (3.4, 1.3, 7.8), (5.2, 1.1, 7.6))
    let big = path((0, 0.4, 5.8), (1.0, 1.4, 7.4), (2.0, 1.3, 7.6), (2.6, 1.2, 6.6), (3.4, 0.9, 5.6), (5.2, 0.7, 4.4))
    return IQScenario(
        id: "pnr-lob", title: "Nobody meets the roller",
        situation: "Pick-and-roll at the top. Their big got caught up at the ball.",
        principle: .ballHandlerRead,
        actors: pnr(handler: handler, screener: screener, onBall: onBall, big: big, bigLabel: "Caught high")
            + spacers(leftCornerD: "Low man"),
        ball: ballWith(handler, until: 2.9,
                       then: flight((3.6, 0.8, 5.0, 3.4), (4.4, 0.4, 3.0, 3.6), (5.2, 0.2, 2.0, 3.1))),
        duration: 5.2, freezeAt: 2.6, gaze: .basket,
        reads: [
            IQRead("lob", "Throw the lob", "Float it over the big to the roller", best: true),
            IQRead("pull", "Pull up", "Shoot it from where you are"),
            IQRead("skip", "Skip it weak", "Cross-court pass to the far corner"),
            IQRead("reset", "Reset", "Back it out and run something else"),
        ],
        why: """
        Two defenders are above the ball and the low man in the far corner has not moved — his \
        feet are still outside the arc next to his own shooter. That means nothing stands between \
        the roller and the rim: the man whose job it was to meet him chose to stay with the corner \
        shooter. Pulling up is a shot into a big who is coming at you, and the skip pass goes to a \
        corner that is guarded. The lob is the open one, and it is open because of a choice the \
        low man made, not because of anything you did.
        """,
        cueActorID: "dlc", clockSeconds: nil, clockLabel: nil,
        source: conventionSource, evidenceGrade: "D")
}

// MARK: - Pick-and-roll: setting the screen

/// 9. You set it, the big drops: roll into the pocket.
private func rollIntoPocket() -> IQScenario {
    let handler = path((0, 3.4, 9.8), (1.0, 2.9, 9.0), (2.0, 1.7, 8.4), (2.8, 0.2, 7.2), (4.0, 0.0, 6.9), (5.0, 0.0, 6.9))
    let screener = path((0, -0.6, 6.6), (0.9, 1.6, 8.6), (2.0, 1.8, 8.5), (2.8, 1.8, 6.9), (4.0, 1.3, 5.4), (5.0, 1.0, 4.6))
    let onBall = path((0, 3.1, 9.0), (1.0, 2.6, 8.3), (2.0, 2.3, 8.1), (2.8, 1.1, 7.7), (4.0, 0.6, 7.2), (5.0, 0.5, 7.1))
    let big = path((0, 0.4, 5.8), (1.0, 1.1, 6.2), (2.0, 1.0, 5.4), (2.8, 0.8, 4.6), (4.0, 0.7, 4.2), (5.0, 0.6, 4.0))
    return IQScenario(
        id: "roll-drop-pocket", title: "You set the screen, he drops",
        situation: "You are the screener. Your man drops towards the rim instead of showing.",
        principle: .screenerRead,
        actors: pnr(handler: handler, screener: screener, onBall: onBall, big: big,
                    handlerIsUser: false, bigLabel: "Your man, dropping", onBallLabel: "His man")
            + spacers(),
        ball: ballWith(handler, until: 4.0, then: flight((4.4, 1.2, 5.6, 1.1), (5.0, 1.0, 4.7, 1.0))),
        duration: 5.0, freezeAt: 2.8, gaze: .basket,
        reads: [
            IQRead("roll", "Roll into the gap", "Roll hard and show your hands at the free-throw line", best: true),
            IQRead("pop", "Pop out", "Step back behind the arc for a shot"),
            IQRead("hold", "Hold the screen", "Stay still and screen again"),
            IQRead("corner", "Cut to the corner", "Drift down to the corner and space"),
        ],
        why: """
        Your man let the ball go by and backed towards the rim, so there is a three-metre hole \
        between him and the ball handler — that hole is the pocket. Rolling into it puts you in \
        front of a defender who is running backwards, and it forces him to pick between you and \
        the ball. Popping only helps when your man came out with you; this one never did.
        """,
        cueActorID: "d5", clockSeconds: nil, clockLabel: nil,
        source: conventionSource, evidenceGrade: "D")
}

/// 10. You set it, your man has to show: pop.
private func popAgainstHedge() -> IQScenario {
    let handler = path((0, 3.4, 9.8), (1.0, 2.9, 9.2), (2.0, 1.8, 8.8), (2.6, 1.2, 9.0), (3.6, 1.2, 9.2), (5.0, 1.3, 9.2))
    let screener = path((0, -0.6, 6.6), (0.9, 1.6, 8.6), (2.4, 3.0, 9.0), (3.4, 3.6, 9.1), (5.0, 3.8, 9.1))
    let onBall = path((0, 3.1, 9.0), (1.0, 2.6, 8.5), (2.0, 2.2, 8.4), (2.6, 1.7, 8.8), (3.6, 1.6, 9.0), (5.0, 1.6, 9.1))
    let big = path((0, 0.4, 5.8), (1.0, 1.4, 7.6), (2.4, 1.1, 9.0), (3.4, 2.0, 9.2), (5.0, 2.8, 9.2))
    return IQScenario(
        id: "pop-hedge", title: "You screened and he showed",
        situation: "You are the screener. Your man jumped out at the ball.",
        principle: .screenerRead,
        actors: pnr(handler: handler, screener: screener, onBall: onBall, big: big,
                    handlerIsUser: false, bigLabel: "Your man, showing", onBallLabel: "His man")
            + spacers(),
        ball: ballWith(handler, until: 3.8, then: flight((4.2, 3.4, 9.1, 1.2), (5.0, 3.8, 9.1, 1.5))),
        duration: 5.0, freezeAt: 2.4, gaze: .ball,
        reads: [
            IQRead("pop", "Pop to the arc", "Step back behind the line and get ready to shoot", best: true),
            IQRead("roll", "Roll to the rim", "Dive down the middle instead"),
            IQRead("wait", "Wait at the screen", "Stand still and let him recover"),
            IQRead("corner", "Drift to the corner", "Slide down the sideline"),
        ],
        why: """
        Your man is out at the ball with his back to the basket and two metres above you, and the \
        weak-side defenders have sunk into the paint. Rolling would take you straight into those \
        two. Popping takes you to the one piece of floor your man cannot get back to in time, \
        because he has to turn and run to cover it. Catch it ready to shoot: the space is real but \
        it only lasts about a second.
        """,
        cueActorID: "d5", clockSeconds: nil, clockLabel: nil,
        source: conventionSource, evidenceGrade: "D")
}

// MARK: - Drive and kick

/// 11. The low man steps up: kick to the corner he left.
private func driveBaselineLowMan() -> IQScenario {
    let handler = path((0, 5.0, 6.1), (0.8, 5.6, 4.6), (1.8, 5.4, 2.8), (2.6, 4.2, 1.8), (4.4, 3.4, 1.6))
    let onBall = path((0, 4.3, 5.6), (0.8, 5.2, 4.4), (1.8, 5.8, 3.6), (2.6, 5.6, 2.8), (4.4, 5.0, 2.4))
    let lowMan = path((0, -5.9, 2.3), (1.2, -4.2, 2.2), (2.2, -2.0, 2.0), (3.0, -1.2, 1.9), (4.4, -1.0, 1.9))
    return IQScenario(
        id: "drive-baseline-lowman", title: "The low man steps up",
        situation: "You drive baseline out of a closeout.",
        principle: .driveAndKick,
        actors: [
            IQActor("user", "You", .offence, user: true, handler),
            IQActor("d1", "Your man", .defence, onBall),
            IQActor("big", "Your big", .offence, at(-1.6, 4.2)),
            IQActor("d5", "Their big", .defence, at(-1.2, 3.4)),
            IQActor("lc", "Corner", .offence, at(-6.6, 1.6)),
            IQActor("dlc", "Low man", .defence, lowMan),
            IQActor("lw", "Wing", .offence, at(-5.0, 6.1)),
            IQActor("dlw", "Wing D", .defence, at(-4.3, 5.6)),
            IQActor("top", "Top", .offence, at(0.6, 8.6)),
            IQActor("dtop", "Top D", .defence, at(0.5, 7.7)),
        ],
        ball: ballWith(handler, until: 2.8, then: flight((3.3, -3.0, 1.8, 1.4), (4.4, -6.4, 1.6, 1.3))),
        duration: 4.4, freezeAt: 2.4, gaze: .basket,
        reads: [
            IQRead("corner", "Kick to the corner", "Pass to the shooter the low man left", best: true),
            IQRead("finish", "Finish over him", "Take it up into the help"),
            IQRead("top", "Pass back to the top", "Kick it back the way it came"),
            IQRead("lob", "Lob to your big", "Throw it up over the defence"),
        ],
        why: """
        The low man — the defender from the far corner — has both feet in the paint and his chest \
        turned to you. He is the one stopping your layup, and the moment he stepped in he stopped \
        guarding anybody. The man he left is standing in the corner, the shortest, straightest \
        pass on the floor from where you are. Finishing over him is a contested shot you chose \
        when an open one was on offer.
        """,
        cueActorID: "dlc", clockSeconds: nil, clockLabel: nil,
        source: conventionSource, evidenceGrade: "D")
}

/// 12. Nobody helps: finish it. (The scenario that stops "always pass" from winning.)
private func driveMiddleNoHelp() -> IQScenario {
    let handler = path((0, 5.0, 6.1), (0.8, 4.0, 5.2), (1.8, 2.6, 4.0), (2.8, 1.0, 2.4), (4.0, 0.4, 1.9))
    let onBall = path((0, 4.3, 5.6), (0.8, 3.8, 5.0), (1.8, 3.6, 4.6), (2.8, 2.4, 3.2), (4.0, 1.6, 2.4))
    return IQScenario(
        id: "drive-middle-stay", title: "Nobody comes",
        situation: "You drive in off the wing with the paint in front of you.",
        principle: .driveAndKick,
        actors: [
            IQActor("user", "You", .offence, user: true, handler),
            IQActor("d1", "Your man", .defence, onBall),
            IQActor("big", "Your big", .offence, at(4.4, 1.8)),
            IQActor("d5", "Their big", .defence, at(4.0, 2.2)),
            IQActor("lc", "Corner", .offence, at(-6.6, 1.6)),
            IQActor("dlc", "Low man", .defence, at(-5.8, 2.2)),
            IQActor("lw", "Wing", .offence, at(-5.0, 6.1)),
            IQActor("dlw", "Tagger", .defence, at(-4.2, 5.4)),
            IQActor("top", "Top", .offence, at(0.6, 8.6)),
            IQActor("dtop", "Top D", .defence, at(0.6, 7.7)),
        ],
        ball: ballWith(handler, until: 3.0, then: flight((3.5, 0.2, 2.0, 2.6), (4.0, 0.0, 1.7, 3.05))),
        duration: 4.0, freezeAt: 1.8, gaze: .basket,
        reads: [
            IQRead("finish", "Finish at the rim", "Take it all the way up", best: true),
            IQRead("corner", "Kick to the corner", "Pass out to a shooter"),
            IQRead("big", "Dump it to your big", "Hand it off inside"),
            IQRead("out", "Pull it back out", "Stop and reset the offence"),
        ],
        why: """
        Check the weak side before you decide: the low man is still standing in the far corner \
        with both feet outside the arc, and the man above him has not stepped in either. Nobody \
        is in the paint, and the only body between you and the rim is the one you have already \
        beaten. There is no help, so there is no pass better than this layup. Passing here is not \
        being unselfish — it hands a two-point shot back and gives the defence the second it needed.
        """,
        cueActorID: "dlc", clockSeconds: nil, clockLabel: nil,
        source: conventionSource, evidenceGrade: "D")
}

/// 13. The tagger leaves the roller: dump it.
private func driveTagger() -> IQScenario {
    let handler = path((0, 5.0, 6.1), (0.8, 4.2, 5.4), (1.8, 3.0, 4.4), (2.8, 1.6, 3.0), (4.2, 1.0, 2.4))
    let roller = path((0, 1.6, 6.0), (1.2, 1.2, 4.0), (2.2, 1.0, 2.6), (3.2, 0.9, 2.2), (4.2, 0.9, 2.0))
    let tagger = path((0, -4.2, 5.4), (1.2, -2.6, 4.4), (2.2, -1.0, 3.4), (3.0, -0.6, 3.0), (4.2, -0.8, 3.2))
    return IQScenario(
        id: "drive-tagger", title: "The tagger leaves the roller",
        situation: "You drive middle and the weak-side defender steps across.",
        principle: .driveAndKick,
        actors: [
            IQActor("user", "You", .offence, user: true, handler),
            IQActor("d1", "Your man", .defence, path((0, 4.3, 5.6), (0.8, 4.2, 5.0), (1.8, 4.0, 4.8), (2.8, 2.8, 3.6), (4.2, 2.2, 3.0))),
            IQActor("big", "Roller", .offence, roller),
            IQActor("d5", "Their big", .defence, path((0, 0.6, 4.6), (1.2, 1.6, 3.2), (2.2, 2.2, 2.6), (4.2, 2.4, 2.4))),
            IQActor("lw", "Wing", .offence, at(-5.0, 6.1)),
            IQActor("dlw", "Tagger", .defence, tagger),
            IQActor("lc", "Corner", .offence, at(-6.6, 1.6)),
            IQActor("dlc", "Corner D", .defence, at(-5.9, 2.2)),
            IQActor("rc", "Corner", .offence, at(6.6, 1.6)),
            IQActor("drc", "Corner D", .defence, at(5.9, 2.2)),
        ],
        ball: ballWith(handler, until: 2.4, then: flight((2.8, 1.0, 2.6, 0.8), (3.4, 0.9, 2.2, 1.0), (4.2, 0.4, 1.8, 3.05))),
        duration: 4.2, freezeAt: 1.8, gaze: .basket,
        reads: [
            IQRead("roller", "Drop it to the roller", "Bounce pass under the help", best: true),
            IQRead("finish", "Finish through him", "Go up into the two of them"),
            IQRead("wing", "Kick to the wing", "Swing it out to the weak wing"),
            IQRead("stepback", "Step back and shoot", "Pull out for a jumper"),
        ],
        why: """
        The tagger's job was to bump the roller. Watch him: he has left the roller's back and \
        stepped into your lane, which means the roller now has nobody on him one metre from the \
        rim. The pass is a short bounce under the tagger's arm. Going up through two bodies is a \
        contested shot; kicking out to the wing is a real pass, just a worse one, because the \
        roller's shot is the easiest on the floor.
        """,
        cueActorID: "dlw", clockSeconds: nil, clockLabel: nil,
        source: conventionSource, evidenceGrade: "D")
}

/// 14. Everyone loads to the ball: skip it.
private func driveSkipWeak() -> IQScenario {
    let handler = path((0, 3.6, 7.2), (0.9, 2.8, 5.8), (1.8, 2.2, 4.4), (2.6, 1.8, 3.4), (4.4, 1.6, 3.2))
    return IQScenario(
        id: "drive-skip-weak", title: "Everyone loads to the ball",
        situation: "You drive middle and two defenders sink with you.",
        principle: .driveAndKick,
        actors: [
            IQActor("user", "You", .offence, user: true, handler),
            IQActor("d1", "Your man", .defence, path((0, 3.2, 6.6), (0.9, 2.8, 5.6), (1.8, 2.8, 5.0), (2.6, 2.6, 4.4), (4.4, 2.4, 4.0))),
            IQActor("big", "Your big", .offence, at(2.6, 1.8)),
            IQActor("d5", "Their big", .defence, path((0, 0.6, 3.0), (1.8, 0.6, 3.2), (2.6, 0.4, 3.4), (4.4, 0.4, 3.4))),
            IQActor("lc", "Weak corner", .offence, at(-6.6, 1.6)),
            IQActor("dlc", "His man", .defence, path((0, -5.9, 2.2), (1.4, -4.4, 2.6), (2.4, -2.6, 3.0), (3.2, -2.4, 3.0), (4.4, -3.6, 2.4))),
            IQActor("lw", "Wing", .offence, at(-5.0, 6.1)),
            IQActor("dlw", "Wing D", .defence, path((0, -4.3, 5.6), (2.4, -3.0, 4.6), (4.4, -3.4, 5.0))),
            IQActor("rc", "Corner", .offence, at(6.6, 1.6)),
            IQActor("drc", "Corner D", .defence, at(5.9, 2.2)),
        ],
        ball: ballWith(handler, until: 2.9, then: flight((3.4, -2.0, 2.4, 2.2), (4.4, -6.4, 1.7, 1.4))),
        duration: 4.4, freezeAt: 2.5, gaze: .basket,
        reads: [
            IQRead("skip", "Skip it across", "One long pass to the far corner", best: true),
            IQRead("finish", "Finish it", "Go up between the three of them"),
            IQRead("near", "Near corner", "Pass to the corner on your own side"),
            IQRead("out", "Dribble back out", "Retreat and start again"),
        ],
        why: """
        Count the defenders inside the arc: three of them are now within two steps of your \
        drive, and the far corner's man is one of them — he has drifted two steps into the paint \
        to help the helper. The corner he left is the furthest place on the floor from where all \
        that traffic is. It takes a long pass, and long passes get stolen when they are late, so \
        the skip is right only while he is still drifting in. That is why you look before the \
        last dribble, not after it.
        """,
        cueActorID: "dlc", clockSeconds: nil, clockLabel: nil,
        source: conventionSource, evidenceGrade: "D")
}

// MARK: - Closeouts

/// A four-out spacing with the ball swung to the user on the right wing.
private func closeoutActors(closer: [IQWaypoint], closerLabel: String) -> [IQActor] {
    [
        IQActor("user", "You", .offence, user: true, at(5.0, 6.1)),
        IQActor("d1", closerLabel, .defence, closer),
        IQActor("top", "Passer", .offence, at(0.6, 8.6)),
        IQActor("dtop", "Top D", .defence, at(0.6, 7.6)),
        IQActor("rc", "Corner", .offence, at(6.6, 1.6)),
        IQActor("drc", "Corner D", .defence, at(5.9, 2.3)),
        IQActor("big", "Your big", .offence, at(-1.8, 4.0)),
        IQActor("d5", "Their big", .defence, at(-1.2, 3.2)),
        IQActor("lw", "Wing", .offence, at(-5.0, 6.1)),
        IQActor("dlw", "Wing D", .defence, at(-3.6, 4.8)),
    ]
}

/// 15. Late closeout, hands down: shoot it.
private func closeoutLate() -> IQScenario {
    return IQScenario(
        id: "closeout-late", title: "He is late and low",
        situation: "The ball is swung to you on the wing.",
        principle: .closeout,
        actors: closeoutActors(closer: path((0, 2.6, 4.4), (1.0, 3.4, 5.0), (1.8, 3.9, 5.4), (2.6, 4.6, 5.8), (3.8, 4.8, 6.0)),
                               closerLabel: "Closing late"),
        ball: flight((0, 0.8, 8.6, 1.2), (0.9, 5.0, 6.2, 1.3), (2.4, 5.0, 6.2, 1.3),
                     (3.0, 4.4, 5.0, 3.4), (3.4, 2.6, 3.4, 4.4), (3.8, 0.4, 1.8, 3.05)),
        duration: 3.8, freezeAt: 1.4, gaze: .basket,
        reads: [
            IQRead("shoot", "Shoot it", "Catch it ready and go straight up", best: true),
            IQRead("drive", "Drive past him", "Put it down and attack"),
            IQRead("swing", "Swing it on", "Move it to the next man"),
            IQRead("fake", "Shot fake first", "Fake, then decide"),
        ],
        why: """
        He is still three metres away with both hands below his waist when the ball gets to you. \
        Nothing he does from there can bother the shot — by the time his hand is up the ball is \
        gone. Driving lets him recover on the way; a shot fake wastes the half second that was \
        the whole advantage. When the closeout is late and low, the shot is the read.
        """,
        cueActorID: "d1", clockSeconds: nil, clockLabel: nil,
        source: conventionSource, evidenceGrade: "D")
}

/// 16. Flying closeout: drive past the high hand.
private func closeoutFlying() -> IQScenario {
    return IQScenario(
        id: "closeout-flying", title: "He runs at you",
        situation: "The ball is swung to you on the wing.",
        principle: .closeout,
        actors: closeoutActors(closer: path((0, 2.6, 4.4), (0.7, 3.4, 5.0), (1.3, 4.0, 5.8), (2.0, 4.6, 6.2), (3.6, 5.0, 6.6)),
                               closerLabel: "Flying at you"),
        ball: flight((0, 0.8, 8.6, 1.2), (0.7, 5.0, 6.2, 1.3), (1.8, 5.0, 6.2, 1.2),
                     (2.6, 3.4, 4.4, 1.0), (3.2, 1.6, 2.6, 1.2), (3.6, 0.4, 1.8, 3.05)),
        duration: 3.6, freezeAt: 1.3, gaze: .basket,
        reads: [
            IQRead("drive", "Drive past his hand", "One dribble by the shoulder he leads with", best: true),
            IQRead("shoot", "Shoot over him", "Rise up into the contest"),
            IQRead("swing", "Swing it on", "Pass it to the next man"),
            IQRead("out", "Dribble back out", "Back it up and reset"),
        ],
        why: """
        He is sprinting at you with a high hand and his feet are still in the air — a defender \
        running that fast cannot stop and cannot change direction. That is a great closeout \
        against a shot and a terrible one against a drive. One dribble past the shoulder he is \
        leading with puts him behind you, and everything after that is downhill. Shooting into a \
        hand that is already up is the one thing this closeout is good at stopping.
        """,
        cueActorID: "d1", clockSeconds: nil, clockLabel: nil,
        source: conventionSource, evidenceGrade: "D")
}

/// 17. On time and balanced: move it on.
private func closeoutOnTime() -> IQScenario {
    return IQScenario(
        id: "closeout-set", title: "He is there on time",
        situation: "The ball is swung to you on the wing and the next man is open.",
        principle: .closeout,
        actors: [
            IQActor("user", "You", .offence, user: true, at(5.0, 6.1)),
            IQActor("d1", "Set and balanced", .defence, path((0, 3.2, 4.8), (0.8, 4.0, 5.4), (1.4, 4.15, 5.5), (3.6, 4.15, 5.5))),
            IQActor("rc", "Corner", .offence, at(6.6, 1.6)),
            IQActor("drc", "Corner D", .defence, at(5.7, 2.6)),
            IQActor("top", "Passer", .offence, at(0.6, 8.6)),
            IQActor("dtop", "Top D", .defence, path((0, 0.6, 7.6), (1.4, 2.0, 6.8), (3.6, 2.4, 6.6))),
            IQActor("big", "Your big", .offence, at(-1.8, 4.0)),
            IQActor("d5", "Their big", .defence, at(-1.2, 3.2)),
            IQActor("lw", "Open wing", .offence, at(-5.0, 6.1)),
            IQActor("dlw", "Two passes away", .defence, at(-2.6, 4.4)),
        ],
        ball: flight((0, 0.8, 8.6, 1.2), (0.8, 5.0, 6.2, 1.3), (1.8, 5.0, 6.2, 1.3),
                     (2.6, 0.6, 7.4, 2.0), (3.0, -5.0, 6.2, 1.3), (3.6, -5.0, 6.2, 1.3)),
        duration: 3.6, freezeAt: 1.6, gaze: .basket,
        reads: [
            IQRead("swing", "Swing it on", "Move it to the man two passes away", best: true),
            IQRead("drive", "Drive into him", "Attack a defender who is set"),
            IQRead("shoot", "Shoot it anyway", "Take the contested three"),
            IQRead("iso", "Hold and go one-on-one", "Size him up with the dribble"),
        ],
        why: """
        His feet are chopped, he is balanced, and one hand is up: this closeout is on time, so \
        there is nothing here to attack. But look past him — the defender guarding the far wing \
        has sunk two steps in to help, so that man is wide open, and he is one pass away. Half a \
        second in your hands and the ball is there. The advantage in this possession is real, it \
        is just not yours: your job is to pass it on before the defence catches up to it.
        """,
        cueActorID: "dlw", clockSeconds: nil, clockLabel: nil,
        source: conventionSource, evidenceGrade: "D")
}

// MARK: - Transition

/// 18. 2-on-1, the defender takes the ball: pass.
private func twoOnOneBallStopped() -> IQScenario {
    let handler = path((0, 1.6, 12.4), (1.0, 1.4, 9.4), (1.9, 1.2, 6.6), (2.6, 1.0, 5.0), (3.6, 0.9, 4.6))
    let runner = path((0, -2.2, 11.4), (1.0, -2.0, 8.0), (1.9, -1.8, 4.8), (2.8, -1.4, 3.0), (3.6, -0.6, 2.0))
    let back = path((0, 0.2, 4.6), (0.9, 0.7, 5.4), (1.7, 1.0, 5.8), (2.6, 1.0, 5.4), (3.6, 0.6, 4.2))
    return IQScenario(
        id: "transition-2on1-ball", title: "Two on one, he steps to you",
        situation: "You are running a two-on-one with a runner on your left.",
        principle: .transition,
        actors: [
            IQActor("user", "You", .offence, user: true, handler),
            IQActor("runner", "Runner", .offence, runner),
            IQActor("back", "The one back", .defence, back),
            IQActor("trail", "Trailer", .defence, path((0, 2.4, 16.0), (3.6, 1.8, 11.0))),
        ],
        ball: ballWith(handler, until: 2.1, then: flight((2.6, -1.5, 3.4, 1.3), (3.1, -1.3, 2.8, 1.2), (3.6, -0.4, 1.8, 3.05))),
        duration: 3.6, freezeAt: 1.7, gaze: .basket,
        reads: [
            IQRead("pass", "Pass to the runner", "Give it up and let him finish", best: true),
            IQRead("keep", "Take it yourself", "Drive past him for the layup"),
            IQRead("out", "Pull it back out", "Wait for everyone to catch up"),
            IQRead("lob", "Lob it", "Throw it high over his head"),
        ],
        why: """
        The one defender back has squared his chest to the ball and stepped towards you — he has \
        picked. A defender can only guard one of two people, and the second he picks the ball, \
        the other one is free. Your runner has nobody in front of him. Waiting for the trailer to \
        arrive turns a two-on-one into a two-on-two, which is the only way to lose this.
        """,
        cueActorID: "back", clockSeconds: nil, clockLabel: nil,
        source: conventionSource, evidenceGrade: "D")
}

/// 19. 2-on-1, the defender stays with the runner: finish it yourself.
private func twoOnOneRunnerCovered() -> IQScenario {
    let handler = path((0, 1.6, 12.4), (1.0, 1.4, 9.4), (1.9, 1.2, 6.6), (2.8, 0.8, 3.8), (3.6, 0.4, 2.2))
    let runner = path((0, -2.2, 11.4), (1.0, -2.0, 8.0), (1.9, -1.8, 5.0), (2.8, -1.6, 3.2), (3.6, -1.4, 2.4))
    let back = path((0, 0.2, 4.6), (1.0, -0.6, 5.0), (1.9, -1.3, 4.6), (2.8, -1.8, 3.4), (3.6, -1.8, 2.8))
    return IQScenario(
        id: "transition-2on1-stay", title: "Two on one, he stays with the runner",
        situation: "You are running a two-on-one with a runner on your left.",
        principle: .transition,
        actors: [
            IQActor("user", "You", .offence, user: true, handler),
            IQActor("runner", "Runner", .offence, runner),
            IQActor("back", "The one back", .defence, back),
            IQActor("trail", "Trailer", .defence, path((0, 2.4, 16.0), (3.6, 1.8, 10.0))),
        ],
        ball: ballWith(handler, until: 3.0, then: flight((3.3, 0.4, 2.6, 2.4), (3.6, 0.2, 1.8, 3.05))),
        duration: 3.6, freezeAt: 2.1, gaze: .basket,
        reads: [
            IQRead("keep", "Take the layup", "Straight to the rim yourself", best: true),
            IQRead("pass", "Pass to the runner", "Give it to the man on your left"),
            IQRead("three", "Stop and shoot the three", "Pull up behind the arc"),
            IQRead("wait", "Slow it down", "Wait for the trailer"),
        ],
        why: """
        His feet and shoulders have turned towards your runner — he has picked the pass, which \
        means he has given up the ball. Passing there throws it into the one defender on the \
        floor. Nobody is in front of you, so the rim is a free two points. The rule is the same \
        as the last one and the answer flips: read which one the single defender chose, then take \
        the other.
        """,
        cueActorID: "back", clockSeconds: nil, clockLabel: nil,
        source: conventionSource, evidenceGrade: "D")
}

/// 20. 3-on-2: hit the wing and make the bottom defender choose.
private func threeOnTwo() -> IQScenario {
    let handler = path((0, 0.6, 12.6), (1.0, 0.5, 10.2), (1.9, 0.4, 8.4), (2.6, 0.4, 7.8), (4.0, 0.4, 7.6))
    let rightWing = path((0, 5.2, 12.0), (1.0, 5.4, 9.4), (1.9, 5.2, 7.0), (2.8, 5.0, 5.6), (4.0, 4.6, 4.0))
    let leftWing = path((0, -5.2, 12.0), (1.0, -5.4, 9.4), (1.9, -5.2, 7.0), (2.8, -5.0, 5.2), (4.0, -4.6, 3.4))
    return IQScenario(
        id: "transition-3on2", title: "Three on two",
        situation: "You bring it up the middle with a wide runner on each side.",
        principle: .transition,
        actors: [
            IQActor("user", "You", .offence, user: true, handler),
            IQActor("rw", "Right lane", .offence, rightWing),
            IQActor("lw", "Left lane", .offence, leftWing),
            IQActor("dtop", "Top of the tandem", .defence, path((0, 0.2, 6.4), (1.0, 0.4, 7.0), (1.9, 0.4, 7.4), (2.6, 1.6, 7.0), (4.0, 3.2, 5.8))),
            IQActor("dback", "Bottom of the tandem", .defence, path((0, 0.2, 3.2), (1.9, 0.3, 3.4), (2.8, 1.8, 3.8), (4.0, 3.4, 4.2))),
        ],
        ball: ballWith(handler, until: 2.2, then: flight((2.7, 3.4, 6.2, 1.4), (3.0, 5.0, 5.6, 1.3),
                                                         (3.6, 1.0, 4.2, 1.6), (4.0, -4.6, 3.4, 1.3))),
        duration: 4.0, freezeAt: 2.0, gaze: .basket,
        reads: [
            IQRead("wing", "Pass ahead to the wing", "Hit the runner and keep it moving", best: true),
            IQRead("drive", "Drive at them", "Split the two defenders"),
            IQRead("out", "Pull it out", "Slow down and set the offence"),
            IQRead("trail", "Wait for the trailer", "Hold it until the big arrives"),
        ],
        why: """
        The top defender has stepped up to the ball, so he cannot get back out to the wing. Two \
        defenders can cover the ball and one runner, never both. Passing to the wing makes the \
        bottom defender come out, and the second he does, the other runner is alone at the rim — \
        so the pass you make now is what creates the pass after it. Driving into two defenders \
        gives them the one thing they were short of: time.
        """,
        cueActorID: "dtop", clockSeconds: nil, clockLabel: nil,
        source: conventionSource, evidenceGrade: "D")
}

// MARK: - Late clock

/// 21. Five on the shot clock.
private func lateClockFive() -> IQScenario {
    let handler = path((0, 3.4, 9.8), (1.0, 2.9, 9.0), (2.0, 1.7, 8.4), (2.7, 0.7, 7.2), (3.6, 0.5, 6.8), (4.6, 0.5, 6.8))
    let screener = path((0, -0.6, 6.6), (0.9, 1.6, 8.6), (2.0, 1.7, 8.5), (2.7, 1.8, 6.8), (4.6, 1.2, 4.0))
    let onBall = path((0, 3.1, 9.0), (1.0, 2.6, 8.3), (2.0, 2.3, 8.1), (2.7, 1.7, 7.6), (3.6, 1.1, 7.1), (4.6, 1.0, 7.0))
    let big = path((0, 0.4, 5.8), (1.0, 1.2, 6.4), (2.0, 1.0, 5.4), (2.7, 0.6, 4.8), (4.6, 0.4, 4.4))
    return IQScenario(
        id: "late-clock-five", title: "Five on the shot clock",
        situation: "Pick-and-roll with five seconds left on the shot clock.",
        principle: .lateClock,
        actors: pnr(handler: handler, screener: screener, onBall: onBall, big: big) + spacers(),
        ball: ballWith(handler, until: 3.4, then: flight((4.0, 0.4, 5.4, 3.8), (4.6, 0.1, 2.0, 3.6))),
        duration: 4.6, freezeAt: 2.6, gaze: .basket,
        reads: [
            IQRead("shoot", "Get the shot up", "Take the pull-up the drop gives you", best: true),
            IQRead("better", "Swing it for a better shot", "One more pass around the horn"),
            IQRead("reset", "Reset the offence", "Back it out and run something"),
            IQRead("kick", "Drive and kick", "Get to the paint, then pass out"),
        ],
        why: """
        Five seconds is one action, not two. A drive and a kick and a shot is three things and \
        each one costs about a second, so the "better shot" at the end of it does not exist — the \
        buzzer gets there first, and a shot-clock violation is worth zero points. You already \
        have an open pull-up because the big is sitting in the paint. A decent shot that goes up \
        beats a great shot that does not.
        """,
        cueActorID: "d5", clockSeconds: 5, clockLabel: "Shot clock",
        source: conventionSource, evidenceGrade: "D")
}

/// 22. Down three, eight seconds, no fouls coming.
private func downThreeEightSeconds() -> IQScenario {
    let handler = path((0, 4.4, 10.2), (1.0, 3.6, 9.2), (2.0, 2.8, 8.6), (2.8, 2.6, 8.2), (4.2, 2.6, 8.2))
    return IQScenario(
        id: "late-down-three", title: "Down three, eight seconds",
        situation: "You are three points down. Eight seconds left and they are not fouling.",
        principle: .lateClock,
        actors: [
            IQActor("user", "You", .offence, user: true, handler),
            IQActor("d1", "Your man", .defence, path((0, 4.4, 9.6), (1.0, 3.9, 8.8), (2.0, 3.7, 8.4), (2.8, 3.7, 8.0), (4.2, 3.4, 7.8))),
            IQActor("big", "Your big", .offence, path((0, -0.6, 6.4), (1.6, 1.0, 8.2), (2.6, 1.2, 8.2), (4.2, 1.2, 7.4))),
            IQActor("d5", "Their big", .defence, path((0, -0.4, 5.4), (1.6, 0.8, 6.8), (2.6, 0.6, 6.0), (4.2, 0.6, 5.6))),
            IQActor("lw", "Wing", .offence, at(-5.0, 6.1)),
            IQActor("dlw", "Wing D", .defence, at(-4.3, 5.6)),
            IQActor("lc", "Corner", .offence, at(-6.6, 1.6)),
            IQActor("dlc", "Corner D", .defence, at(-5.9, 2.3)),
            IQActor("rc", "Corner", .offence, at(6.6, 1.6)),
            IQActor("drc", "Corner D", .defence, at(5.9, 2.3)),
        ],
        ball: ballWith(handler, until: 3.0, then: flight((3.6, 1.8, 6.0, 4.0), (4.0, 0.8, 3.6, 4.4), (4.2, 0.2, 1.8, 3.05))),
        duration: 4.2, freezeAt: 2.4, gaze: .basket,
        reads: [
            IQRead("three", "Take the three", "Shoot it — a two does not help", best: true),
            IQRead("two", "Drive for the layup", "Get the easy two and foul after"),
            IQRead("hold", "Hold for the last shot", "Run the clock down further"),
            IQRead("swing", "Swing it once more", "One more pass around"),
        ],
        why: """
        Three points behind means only a three ties it. The layup is the easier shot, but it \
        leaves you one point short with the other team holding the ball and the clock, which is \
        why "get two and foul" is a plan for twenty seconds, not for eight. You are behind the \
        arc with a step of space. Holding longer does not make the shot better — it only means \
        there is no time for a rebound if you miss.
        """,
        cueActorID: nil, clockSeconds: 8, clockLabel: "Game clock",
        source: conventionSource, evidenceGrade: "D")
}

// MARK: - Help defence

/// 23. You are the low man: step up.
private func helpLowManSteps() -> IQScenario {
    let user = path((0, -6.0, 2.3), (1.2, -4.4, 2.2), (2.2, -2.2, 2.0), (3.0, -1.2, 1.9), (4.2, -1.2, 1.9))
    let ballMan = path((0, 5.0, 6.1), (0.8, 5.6, 4.6), (1.8, 5.4, 2.8), (2.6, 4.0, 2.0), (4.2, 2.4, 1.9))
    return IQScenario(
        id: "help-lowman-step", title: "You are the low man",
        situation: "You are guarding the far corner. The ball drives baseline on the other side.",
        principle: .helpDefence,
        actors: [
            IQActor("user", "You", .defence, user: true, user),
            IQActor("lc", "Your man", .offence, at(-6.6, 1.6)),
            IQActor("ball", "Ball", .offence, ballMan),
            IQActor("d1", "Beaten", .defence, path((0, 4.3, 5.6), (0.8, 5.2, 4.4), (1.8, 5.8, 3.4), (2.6, 5.2, 2.4), (4.2, 3.8, 2.2))),
            IQActor("big", "Their big", .offence, at(1.8, 4.2)),
            IQActor("d5", "Your big", .defence, at(1.4, 3.4)),
            IQActor("rw", "Their wing", .offence, at(-5.0, 6.1)),
            IQActor("dw", "Teammate", .defence, at(-4.0, 5.4)),
            IQActor("top", "Their top", .offence, at(0.6, 8.6)),
            IQActor("dtop", "Teammate", .defence, at(0.6, 7.7)),
        ],
        ball: ballWith(ballMan, until: 4.2),
        duration: 4.2, freezeAt: 2.2, gaze: .ball,
        reads: [
            IQRead("step", "Step up and take him", "Meet the ball before it gets to the rim", best: true),
            IQRead("stay", "Stay with your man", "Hold the corner and trust the help"),
            IQRead("double", "Run at the ball", "Sprint out and trap him"),
            IQRead("wait", "Drop under the rim", "Wait at the basket for the layup"),
        ],
        why: """
        Look where you are: you are the lowest defender on the weak side, so on a baseline drive \
        the low man is you — nobody else is between the ball and the rim. Staying at home gives \
        up a layup to save a corner three. Step up early and meet him before the restricted \
        area: early is a charge or a miss, late is an and-one. Your teammates then rotate behind \
        you to your man; that part is their job, not yours.
        """,
        cueActorID: "d1", clockSeconds: nil, clockLabel: nil,
        source: conventionSource, evidenceGrade: "D")
}

/// 24. Somebody else is the low man: stay attached. (The one where "help" is wrong.)
private func helpStayHome() -> IQScenario {
    let user = path((0, -4.0, 5.3), (1.4, -4.0, 5.3), (2.4, -4.0, 5.3), (3.2, -4.4, 5.7), (4.2, -4.7, 5.9))
    let ballMan = path((0, 2.6, 7.9), (0.9, 1.8, 6.4), (1.8, 1.2, 4.6), (2.6, 0.7, 3.2), (4.2, 0.6, 2.8))
    return IQScenario(
        id: "help-stay-home", title: "The low man is somebody else",
        situation: "You are guarding a shooter on the weak-side wing. The ball drives middle.",
        principle: .helpDefence,
        actors: [
            IQActor("user", "You", .defence, user: true, user),
            IQActor("lw", "Your shooter", .offence, at(-5.0, 6.1)),
            IQActor("ball", "Ball", .offence, ballMan),
            IQActor("d1", "Beaten", .defence, path((0, 2.2, 7.2), (0.9, 1.9, 6.2), (1.8, 1.6, 4.8), (2.6, 1.2, 3.6), (4.2, 1.0, 3.0))),
            IQActor("big", "Their big", .offence, at(2.6, 2.4)),
            IQActor("d5", "Your big", .defence, at(2.0, 2.8)),
            IQActor("lc", "Their corner", .offence, at(-6.6, 1.6)),
            IQActor("dlc", "Low man", .defence, path((0, -5.9, 2.3), (1.6, -4.0, 2.2), (2.6, -1.8, 2.2), (4.2, -1.2, 2.2))),
            IQActor("top", "Their top", .offence, at(0.6, 8.6)),
            IQActor("dtop", "Teammate", .defence, at(0.6, 7.7)),
        ],
        ball: ballWith(ballMan, until: 3.0, then: flight((3.5, -3.0, 2.2, 1.6), (4.2, -6.4, 1.7, 1.3))),
        duration: 4.2, freezeAt: 2.2, gaze: .ball,
        reads: [
            IQRead("stay", "Stay attached", "Hold your shooter and let the low man help", best: true),
            IQRead("help", "Step in and help", "Leave him and meet the drive"),
            IQRead("double", "Double the ball", "Go and trap the driver"),
            IQRead("switch", "Switch onto the driver", "Take the ball and leave your man"),
        ],
        why: """
        Two helpers on one drive is one helper too many. The low man in the corner has already \
        stepped in with both feet — the paint is covered. If you leave as well, the drive draws \
        two of you and the kick-out finds the shooter you just let go of, standing on the arc. \
        The hard part of help defence is that most of it is not helping: the discipline is to \
        stay attached when somebody else already has it.
        """,
        cueActorID: "dlc", clockSeconds: nil, clockLabel: nil,
        source: conventionSource, evidenceGrade: "D")
}

// MARK: - The self-check

extension IQScenarioLibrary {
    /// A unit-style check of the maths and of the data, in the style of `CaptureView.geometrySelfCheck`:
    /// it returns the failures, so a run with an empty array is a pass. Called once when the trainer
    /// first opens in a debug build, and the result goes to the activity log.
    static func selfCheck() -> [String] {
        var failures: [String] = []
        func check(_ condition: Bool, _ what: @autoclosure () -> String) {
            if !condition { failures.append(what()) }
        }
        func near(_ a: Double, _ b: Double, _ what: String, _ tolerance: Double = 1e-9) {
            if (a - b).magnitude > tolerance { failures.append("\(what): \(a) ≠ \(b)") }
        }

        // Smoothstep's three fixed points are what make the midpoint check below exact.
        near(IQPath.smoothstep(0), 0, "smoothstep(0)")
        near(IQPath.smoothstep(1), 1, "smoothstep(1)")
        near(IQPath.smoothstep(0.5), 0.5, "smoothstep(0.5)")
        near(IQPath.smoothstep(-3), 0, "smoothstep clamps low")
        near(IQPath.smoothstep(9), 1, "smoothstep clamps high")

        // Interpolation: endpoints exact, midpoint halfway, held outside the track.
        let track = path((1.0, 0, 0), (3.0, 4, 8))
        near(IQPath.position(track, at: 1.0).x, 0, "track start x")
        near(IQPath.position(track, at: 3.0).z, 8, "track end z")
        near(IQPath.position(track, at: 2.0).x, 2, "track midpoint x")
        near(IQPath.position(track, at: 2.0).z, 4, "track midpoint z")
        near(IQPath.position(track, at: -5).x, 0, "track held before the start")
        near(IQPath.position(track, at: 99).x, 4, "track held after the end")
        near(IQPath.position([], at: 1).x, 0, "empty track is the origin")
        near(IQPath.position(at(2, 3), at: 7).z, 3, "one-waypoint track stands still")
        // Heights: a waypoint without one falls back to the default, and the two mix linearly.
        near(IQPath.position(path((0, 0, 0), (2, 0, 0)), at: 1, defaultHeight: 1.4).y, 1.4, "default height")
        near(IQPath.position([IQWaypoint(0, 0, 0, 1), IQWaypoint(2, 0, 0, 3)], at: 1).y, 2, "height midpoint")
        // Three segments: the seam between them is the waypoint itself, not an interpolation of it.
        let three = path((0, 0, 0), (1, 5, 0), (2, 5, 5))
        near(IQPath.position(three, at: 1).x, 5, "three-segment seam x")
        near(IQPath.position(three, at: 1).z, 0, "three-segment seam z")

        // The court numbers agree with the rulebook table they came from.
        near(IQCourt.cornerLineX, 6.6, "corner line 0.90 m inside the sideline", 1e-9)
        if let z = IQCourt.arcZ(atX: 0) { near(z, IQCourt.basketZ + 6.75, "arc at the top of the key") }
        else { failures.append("arc at x = 0 is missing") }
        check(IQCourt.arcZ(atX: 7.0) == nil, "arc must not exist beyond its own radius")

        // The scenarios themselves.
        check(all.count >= 16, "only \(all.count) scenarios")
        var seen = Set<String>()
        for s in all {
            let id = s.id
            check(seen.insert(id).inserted, "duplicate scenario id \(id)")
            check(s.reads.count >= 3 && s.reads.count <= 4, "\(id): \(s.reads.count) options")
            check(s.reads.filter(\.isBest).count == 1, "\(id): must have exactly one best read")
            check(Set(s.reads.map(\.id)).count == s.reads.count, "\(id): duplicate option ids")
            check(s.actors.filter(\.isUser).count == 1, "\(id): must have exactly one user")
            check(s.freezeAt > 0.5 && s.freezeAt < s.duration, "\(id): freeze at \(s.freezeAt) of \(s.duration)")
            check(!s.why.isEmpty && s.why.count > 120, "\(id): the why is too short to name a cue")
            check(!s.title.isEmpty && !s.situation.isEmpty, "\(id): missing title or situation")
            check(s.evidenceGrade == "D", "\(id): grade \(s.evidenceGrade) — nothing here is measured")
            check((s.clockSeconds == nil) == (s.clockLabel == nil), "\(id): a clock needs both a number and a name")
            if let cue = s.cueActorID {
                check(s.actors.contains { $0.id == cue }, "\(id): cue \(cue) is not on the floor")
            }
            if case .actor(let target) = s.gaze {
                check(s.actors.contains { $0.id == target }, "\(id): gaze at \(target), who is not on the floor")
            }
            check(s.ball.count >= 2, "\(id): the ball needs a track")

            // What the camera can actually see at the freeze. A read the picture cannot show is
            // not a read, it is a guess, so these three are hard failures rather than notes.
            let t = s.freezeAt
            if let cue = s.cueActorID, let actor = s.actors.first(where: { $0.id == cue }) {
                let p = IQPath.position(actor.track, at: t)
                let bearing = s.bearingDegrees(to: p, at: t)
                check(bearing.magnitude <= IQCamera.halfFieldOfViewDegrees - 2,
                      "\(id): the cue (\(actor.label)) is \(Int(bearing))° off centre — off the picture")
            }
            var inShot = 0
            for actor in s.actors where !actor.isUser {
                let p = IQPath.position(actor.track, at: t)
                let d = s.distanceFromUser(to: p, at: t)
                check(d >= IQCamera.minimumClearance,
                      "\(id): \(actor.label) is \(String(format: "%.2f", d)) m away at the freeze — inside the lens")
                if s.bearingDegrees(to: p, at: t).magnitude <= IQCamera.halfFieldOfViewDegrees { inShot += 1 }
            }
            check(inShot >= 2, "\(id): only \(inShot) players in shot at the freeze")
            for track in s.actors.map(\.track) + [s.ball] {
                var last = -Double.infinity
                for w in track {
                    check(w.t >= last, "\(id): waypoint times run backwards")
                    last = w.t
                    check(w.x.magnitude <= IQCourt.halfWidth + 0.6, "\(id): x \(w.x) is off the side of the court")
                    check(w.z >= -0.6 && w.z <= IQCourt.halfLength + 2.2, "\(id): z \(w.z) is off the end of the court")
                }
            }
            // Every principle must be reachable, and the answer must not always be "pass".
            check(IQPrinciple.allCases.contains(s.principle), "\(id): unknown principle")
        }
        for principle in IQPrinciple.allCases {
            check(all.contains { $0.principle == principle },
                  "no scenario trains \(principle.title)")
        }
        return failures
    }
}
