import Foundation

// ================================================================================================
// MARK: - The quiz
// ================================================================================================
//
// Forty-four multiple-choice questions, stored as data so the screen that shows them holds no
// knowledge of its own. Every question says where its answer comes from (`IQSource`), because
// "the rulebook says so" and "most coaches do it this way" are different kinds of answer and the
// second kind is arguable. Where FIBA and the NBA differ, the question names the book it is
// asking about instead of pretending there is one answer.
//
// Rule details were written against the same rulebooks cited in
// `docs/reference/sdk-and-licensing-research-2026-09-12.md` §6; the court distances used in the
// questions are the verified ones from that table.

enum IQQuizTopic: String, Codable, Sendable, CaseIterable {
    case rules, situations, clock

    var title: String {
        switch self {
        case .rules: return "Rules"
        case .situations: return "Situations"
        case .clock: return "Clock and score"
        }
    }
}

/// Where an answer comes from. Shown under every rationale.
enum IQSource: String, Codable, Sendable {
    case fiba, nba, bothBooks, courtMaths, convention

    var label: String {
        switch self {
        case .fiba: return "FIBA rulebook"
        case .nba: return "NBA rulebook"
        case .bothBooks: return "FIBA and NBA agree on this one"
        case .courtMaths: return "Court dimensions (FIBA), plus arithmetic"
        case .convention: return "Coaching convention — widely taught, not measured"
        }
    }
}

struct IQQuestion: Identifiable, Sendable {
    var id: String
    var topic: IQQuizTopic
    var question: String
    var options: [String]
    var correctIndex: Int
    /// One sentence. Why that answer, not the others.
    var rationale: String
    var source: IQSource

    init(_ id: String, _ topic: IQQuizTopic, _ question: String, _ options: [String],
         _ correctIndex: Int, _ rationale: String, _ source: IQSource) {
        self.id = id; self.topic = topic; self.question = question; self.options = options
        self.correctIndex = correctIndex; self.rationale = rationale; self.source = source
    }

    var correctAnswer: String { options[correctIndex] }
}

enum IQQuizBank {
    static let all: [IQQuestion] = rules + situations + clock

    static func question(id: String) -> IQQuestion? { all.first { $0.id == id } }

    /// A round: ten questions, spread across the three topics so a round is never all rules.
    static func round(count: Int = 10, using generator: inout SystemRandomNumberGenerator) -> [IQQuestion] {
        var picked: [IQQuestion] = []
        let perTopic = max(1, count / IQQuizTopic.allCases.count)
        for topic in IQQuizTopic.allCases {
            picked += all.filter { $0.topic == topic }.shuffled(using: &generator).prefix(perTopic)
        }
        let rest = all.filter { q in !picked.contains(where: { $0.id == q.id }) }.shuffled(using: &generator)
        picked += rest.prefix(max(0, count - picked.count))
        return picked.shuffled(using: &generator)
    }

    // MARK: Rules

    static let rules: [IQQuestion] = [
        IQQuestion("q-shotclock", .rules,
                   "How long is the shot clock?",
                   ["24 seconds", "30 seconds", "35 seconds", "It depends on the half"], 0,
                   "Both books use a 24-second shot clock for a new possession.", .bothBooks),
        IQQuestion("q-oreb-reset", .rules,
                   "Your team gets an offensive rebound off a shot that hit the rim. What does the shot clock go to?",
                   ["14 seconds", "24 seconds", "It keeps running", "20 seconds"], 0,
                   "An offensive rebound resets the clock to 14, not to a full 24.", .bothBooks),
        IQQuestion("q-backcourt-8", .rules,
                   "How long do you have to get the ball over the half-way line?",
                   ["8 seconds", "10 seconds", "5 seconds", "There is no limit"], 0,
                   "Eight seconds, and the count does not stop because you are being pressed.", .bothBooks),
        IQQuestion("q-backcourt-return", .rules,
                   "You dribble into the front court, then step back over the half-way line with the ball. What is it?",
                   ["A backcourt violation — the ball goes over", "Nothing, you may go back once",
                    "A jump ball", "A five-second count starts"], 0,
                   "Once your team has established the ball in the front court you cannot take it back.", .bothBooks),
        IQQuestion("q-three-seconds", .rules,
                   "How long may an attacker stand in the painted area?",
                   ["Under 3 seconds while your team has the ball in the front court", "5 seconds",
                    "As long as they keep moving their feet", "There is no limit for the ball handler"], 0,
                   "Three seconds in the key is a violation while your team controls the ball in the front court.", .bothBooks),
        IQQuestion("q-def-three", .rules,
                   "In the NBA, what happens if a defender stands in the paint for three seconds without guarding anyone?",
                   ["One technical free throw and the offence keeps the ball", "Nothing — it is legal",
                    "A jump ball", "Two free throws"], 0,
                   "The NBA has a defensive three-second rule; FIBA does not, which is why FIBA defences can sit in the paint.", .nba),
        IQQuestion("q-fouls-out-fiba", .rules,
                   "In a FIBA game, how many fouls before you are out?",
                   ["5", "6", "4", "7"], 0,
                   "Five in FIBA, six in the NBA — the same player, two different books.", .fiba),
        IQQuestion("q-fouls-out-nba", .rules,
                   "In an NBA game, how many personal fouls before you are out?",
                   ["6", "5", "7", "4"], 0,
                   "Six, because NBA quarters are twelve minutes rather than ten.", .nba),
        IQQuestion("q-bonus-fiba", .rules,
                   "In FIBA, from which team foul in a quarter does the other team shoot two free throws for any foul?",
                   ["The fifth", "The fourth", "The sixth", "The seventh"], 0,
                   "From a team's fifth foul in that quarter, every further defensive foul is two shots.", .fiba),
        IQQuestion("q-three-shot-foul", .rules,
                   "You are fouled while shooting a three and you miss. How many free throws?",
                   ["Three", "Two", "One", "Two, plus the ball"], 0,
                   "A missed shot gets you as many free throws as the shot was worth.", .bothBooks),
        IQQuestion("q-and-one", .rules,
                   "You are fouled, and the shot still goes in. What do you get?",
                   ["The basket and one free throw", "The basket only", "Two free throws instead of the basket",
                    "The basket and the ball back"], 0,
                   "The basket counts and you shoot one — the \"and one\".", .bothBooks),
        IQQuestion("q-goaltend", .rules,
                   "A defender swats the ball away when it is on its way down towards the rim, above rim height. What is it?",
                   ["Goaltending — the basket counts", "A clean block", "A jump ball", "A technical foul"], 0,
                   "Touching a shot on its downward flight above the ring counts the basket for the shooter.", .bothBooks),
        IQQuestion("q-interference", .rules,
                   "Your teammate tips the ball in while it is still sitting on the ring. What is it?",
                   ["Basket interference — no points", "A tip-in, two points", "A foul on the defence", "A jump ball"], 0,
                   "Touching the ball while it is on the ring or inside the cylinder cancels it.", .bothBooks),
        IQQuestion("q-travel", .rules,
                   "You catch the ball, pivot on your left foot, then lift that foot and dribble. Legal?",
                   ["No — the dribble must start before the pivot foot leaves the floor", "Yes, always",
                    "Yes, if you land on both feet", "Only if nobody is guarding you"], 0,
                   "The pivot foot may leave the floor to pass or shoot, but not before the ball leaves your hand on a dribble.", .bothBooks),
        IQQuestion("q-gather", .rules,
                   "How many steps may you take after you gather the ball at the end of a dribble?",
                   ["Two", "One", "Three", "None"], 0,
                   "Two steps after the gather, in both books.", .bothBooks),
        IQQuestion("q-double-dribble", .rules,
                   "You stop your dribble, hold the ball, then start dribbling again. What is it?",
                   ["A violation — the ball goes over", "Legal if you did not move your feet",
                    "Legal once per possession", "A held ball"], 0,
                   "Picking the ball up ends your dribble for that possession.", .bothBooks),
        IQQuestion("q-inbound-5", .rules,
                   "How long do you have to release a throw-in?",
                   ["5 seconds", "8 seconds", "3 seconds", "10 seconds"], 0,
                   "Five seconds from when the ball is at your disposal.", .bothBooks),
        IQQuestion("q-baseline-run", .rules,
                   "After the other team scores, may you run along the baseline before the inbound pass?",
                   ["Yes", "No, you must stay in one spot", "Only in the last two minutes",
                    "Only after a timeout"], 0,
                   "You may move along the endline after a made basket; after a violation or foul you may not.", .bothBooks),
        IQQuestion("q-held-ball-fiba", .rules,
                   "In FIBA, two players get both hands firmly on the ball. What happens?",
                   ["The possession arrow decides", "They jump for it", "The defence gets it",
                    "The team that called it first gets it"], 0,
                   "FIBA uses alternating possession; the NBA jumps for it.", .fiba),
        IQQuestion("q-charge-circle", .rules,
                   "A help defender is standing under the basket, inside the semicircle, when the driver runs into him. What is it?",
                   ["A blocking foul — no charge can be taken in there", "A charge", "No call", "A jump ball"], 0,
                   "The no-charge semicircle exists so help defenders cannot camp under the rim and take charges.", .bothBooks),
        IQQuestion("q-screen", .rules,
                   "You set a screen on a defender who is moving. What do you owe him?",
                   ["Enough room to stop or change direction — about a step", "Nothing, he must go round",
                    "You must call out the screen", "You must stand still for three seconds first"], 0,
                   "A screen on a moving opponent must give him room to avoid it; on a stationary one it need not.", .bothBooks),
        IQQuestion("q-five-second-fiba", .rules,
                   "In FIBA, you hold the ball with a defender right on you and do not pass, shoot or dribble. How long before it is a violation?",
                   ["5 seconds", "8 seconds", "3 seconds", "It is never a violation"], 0,
                   "FIBA's closely guarded count is five seconds while a defender is within about a metre.", .fiba),
        IQQuestion("q-quarters", .rules,
                   "How long is a FIBA quarter?",
                   ["10 minutes", "12 minutes", "8 minutes", "20 minutes"], 0,
                   "FIBA plays 4 × 10; the NBA plays 4 × 12.", .fiba),
        IQQuestion("q-overtime", .rules,
                   "How long is an overtime period?",
                   ["5 minutes", "3 minutes", "4 minutes", "The same as a quarter"], 0,
                   "Five minutes, and as many as it takes to break the tie.", .bothBooks),
        IQQuestion("q-unsportsmanlike", .rules,
                   "In FIBA, what does an unsportsmanlike foul cost the defence?",
                   ["Free throws and the ball back for the other team", "One free throw only",
                    "Nothing extra", "Two free throws with no possession"], 0,
                   "Free throws plus possession is what separates it from an ordinary foul.", .fiba),
    ]

    // MARK: Situations

    static let situations: [IQQuestion] = [
        IQQuestion("q-corner-three", .rules,
                   "On a FIBA court, which three is the shortest shot?",
                   ["The corner", "The top of the key", "The wing", "They are all 6.75 m"], 0,
                   "The corner line sits 0.90 m inside the sideline, so it is 6.60 m from the basket against 6.75 m at the top.",
                   .courtMaths),
        IQQuestion("q-low-man", .situations,
                   "Who is \"the low man\" on defence?",
                   ["The weak-side defender nearest the baseline, whose job is to stop a drive to the rim",
                    "The shortest player on the floor", "The defender guarding the ball",
                    "The player boxing out at the free-throw line"], 0,
                   "The low man is a job, not a person: whoever is lowest on the help side takes the drive.", .convention),
        IQQuestion("q-tagger", .situations,
                   "What is a \"tagger\" doing in a pick-and-roll defence?",
                   ["Bumping the roller from the weak side so the big cannot catch it at the rim",
                    "Trapping the ball handler", "Denying the corner pass", "Boxing out early"], 0,
                   "The tag buys the big time to recover; the cost is that the tagger leaves his own man for a moment.", .convention),
        IQQuestion("q-ice", .situations,
                   "What does it mean to \"ice\" a side pick-and-roll?",
                   ["Jump above the screen and force the ball down the sideline", "Switch every screen",
                    "Trap the ball with two defenders", "Go under the screen and sit in the paint"], 0,
                   "Icing turns the sideline into an extra defender and keeps the ball out of the middle.", .convention),
        IQQuestion("q-drop", .situations,
                   "What does drop coverage give up on purpose?",
                   ["The shot in front of the big", "The lob", "The layup", "The corner three"], 0,
                   "Drop protects the rim and the roller, and pays for it with the pull-up.", .convention),
        IQQuestion("q-half-second", .situations,
                   "What is the \"half-second\" rule on offence?",
                   ["Shoot, pass or drive within about half a second of catching it", "Hold the ball for half a second before shooting",
                    "Get the shot off in the last half second", "Count half a second before helping"], 0,
                   "The idea is that an advantage decays: a defence catches up to a ball that sits still.", .convention),
        IQQuestion("q-closeout-late", .situations,
                   "A defender closes out at you late with his hands down. What is the read?",
                   ["Shoot it", "Drive past him", "Swing it on", "Shot fake, then drive"], 0,
                   "Hands down and three metres away means nothing he does can reach the shot.", .convention),
        IQQuestion("q-closeout-fast", .situations,
                   "A defender sprints at you out of control with a high hand. What is the read?",
                   ["Drive past the shoulder he leads with", "Shoot over the hand", "Pass it back out",
                    "Dribble backwards"], 0,
                   "A defender running that fast can contest a shot but cannot change direction.", .convention),
        IQQuestion("q-help-two", .situations,
                   "Two defenders step in to stop the same drive. What has the offence gained?",
                   ["An open shooter, because two helpers means somebody is unguarded",
                    "Nothing", "A free throw", "A better rebound position"], 0,
                   "Five defenders cover five attackers; the second helper is the one who leaves somebody open.", .convention),
        IQQuestion("q-spacing", .situations,
                   "Why do coaches want shooters standing in the corners rather than along the baseline near the rim?",
                   ["It is a three, and it pulls the help defender furthest from the paint",
                    "It is closer to the basket", "It is easier to rebound from",
                    "It stops the other team fast breaking"], 0,
                   "Corner spacing is about the distance the helper has to travel as much as about the shot.", .convention),
        IQQuestion("q-box-out", .situations,
                   "A shot goes up from the right wing. Where does the ball most often come down?",
                   ["The opposite side of the rim", "Straight back to the shooter", "In the corner",
                    "It is completely random"], 0,
                   "Long shots miss long and often cross the rim, which is why weak-side rebounding is coached.",
                   .convention),
        IQQuestion("q-switch-attack", .situations,
                   "They switch a big onto you. When is the best moment to attack him?",
                   ["Immediately, before the help gets set", "After eight seconds of sizing him up",
                    "After a pass and a cut", "Only after a second screen"], 0,
                   "A switch is an advantage that shrinks every second the defence gets to reorganise.", .convention),
        IQQuestion("q-reject", .situations,
                   "The defence is forcing you into a screen you do not want. What is the counter called?",
                   ["Rejecting the screen", "Slipping the screen", "Re-screening", "Flaring"], 0,
                   "Refusing the screen attacks the side the defender has vacated by over-playing.", .convention),
        IQQuestion("q-slip", .situations,
                   "The screener leaves early, before contact, because his man jumped out to trap. That is called…",
                   ["Slipping the screen", "Icing", "Flaring", "Rejecting"], 0,
                   "A slip punishes a defender who leaves early to help on the ball.", .convention),
        IQQuestion("q-pocket", .situations,
                   "What is a \"pocket pass\"?",
                   ["A short, low pass into the gap behind a hedging big",
                    "A long cross-court pass", "A lob to the rim", "A pass to the corner"], 0,
                   "It goes into the space the big left when he came out at the ball.", .convention),
        IQQuestion("q-shot-quality", .situations,
                   "Which of these is usually the best shot available?",
                   ["An open layup", "An open corner three", "A contested three", "An open long two"], 0,
                   "A layup is the highest-percentage shot on the floor; the open corner three is next.", .convention),
    ]

    // MARK: Clock and score

    static let clock: [IQQuestion] = [
        IQQuestion("q-down3-late", .clock,
                   "Down 3, eight seconds left, you have the ball and they are not fouling. What do you play for?",
                   ["A three", "A layup, then foul", "The best shot, two or three",
                    "Hold it for the very last second"], 0,
                   "Only a three ties it, and eight seconds is not enough to score two and get the ball back.", .convention),
        IQQuestion("q-down3-30", .clock,
                   "Down 3 with 30 seconds left and you have the ball. What do most coaches want?",
                   ["A quick two, then foul straight away", "A three straight away",
                    "Hold for the last shot", "Drive and get fouled"], 0,
                   "Thirty seconds is enough for two possessions, so the quick two keeps both chances alive; coaches do argue about this one.",
                   .convention),
        IQQuestion("q-up3-foul", .clock,
                   "Up 3 on defence with six seconds left and they have the ball. What is the common convention?",
                   ["Foul before they can shoot a three", "Guard the line and let them shoot",
                    "Trap the ball handler", "Back off and protect the paint"], 0,
                   "Fouling makes a tie impossible on that possession, though plenty of coaches disagree and play it straight.",
                   .convention),
        IQQuestion("q-up2-nofoul", .clock,
                   "Up 2 on defence with eight seconds left. Should you foul?",
                   ["No — a foul gives them two free throws to tie", "Yes, always foul",
                    "Only if they have the ball past half way", "Only in the NBA"], 0,
                   "Up 3 a foul takes the tie away; up 2 it hands them the tie for free.", .convention),
        IQQuestion("q-two-for-one", .clock,
                   "There are 38 seconds left in the quarter and you have the ball. What is a \"two-for-one\"?",
                   ["Shoot by about 30 seconds so you get the ball back for the last shot",
                    "Take two shots in one possession", "Foul twice quickly",
                    "Hold the ball so they get no shot"], 0,
                   "If your shot goes up with about 30 seconds left, their 24-second clock still leaves you a last possession.",
                   .convention),
        IQQuestion("q-last-shot", .clock,
                   "Tied game, you have the ball with 30 seconds left and the shot clock is off. When do you want the shot up?",
                   ["With about 5 seconds left", "Straight away", "With 15 seconds left",
                    "On the buzzer exactly"], 0,
                   "Shoot around five seconds and they have no time to answer, but you still have time for your own rebound.",
                   .convention),
        IQQuestion("q-shotclock-off", .clock,
                   "When does the shot clock stop mattering at the end of a game?",
                   ["When the game clock has less time left than the shot clock would",
                    "In the last two minutes", "In overtime only", "It always matters"], 0,
                   "The shot clock is switched off once it cannot expire before the game clock does.", .bothBooks),
        IQQuestion("q-down6-40", .clock,
                   "Down 6 with 40 seconds left and they have the ball. What do you do?",
                   ["Foul immediately — you need two possessions and the clock is the enemy",
                    "Play defence and hope for a stop", "Call a timeout and set the defence",
                    "Press and trap without fouling"], 0,
                   "Two scores means two possessions, and letting them hold the ball costs you one of them.", .convention),
        IQQuestion("q-down4-25", .clock,
                   "Down 4 with 25 seconds and the ball. Is a three the answer?",
                   ["Not on its own — you need two scores either way, so take the quickest good shot",
                    "Yes, two threes win it", "No, only free throws can win it",
                    "Yes, and then hold the ball"], 0,
                   "Four points is two possessions whatever the first shot is worth, so time matters more than shot value.",
                   .convention),
        IQQuestion("q-bonus-drive", .clock,
                   "The other team is in the bonus with two minutes to go. How does that change your offence?",
                   ["Driving into contact is worth more, because any foul is two free throws",
                    "It does not change anything", "You should shoot more threes",
                    "You should hold the ball longer"], 0,
                   "In the bonus, contact you draw turns into free throws instead of a throw-in.", .bothBooks),
        IQQuestion("q-ft-miss", .clock,
                   "Down 3, at the line for two, four seconds left and no timeouts. What is the convention?",
                   ["Make the first, then miss the second on purpose off the rim to try to rebound",
                    "Make both and foul", "Miss both deliberately", "Make both and press"], 0,
                   "Making both still leaves you one point short with no time to get the ball back.", .convention),
        IQQuestion("q-stop-clock", .clock,
                   "In the last two minutes, does the clock stop when a basket is made?",
                   ["Yes, in the last two minutes of the fourth quarter and overtime", "No, never",
                    "Only on free throws", "Only if a timeout is called"], 0,
                   "Both books stop the clock on a made field goal at the end of the game, which is what makes late fouling work.",
                   .bothBooks),
        IQQuestion("q-advance", .clock,
                   "You call a timeout in your own backcourt in the last two minutes. Where do you inbound?",
                   ["In the front court — the ball is advanced", "Where the ball was",
                    "At the half-way line only in the NBA", "Under your own basket"], 0,
                   "Both books let you advance the ball after a late timeout, which is worth about six seconds of clock.",
                   .bothBooks),
        IQQuestion("q-timeouts-fiba", .clock,
                   "In FIBA, how many timeouts can a team use in the second half?",
                   ["Three, with no more than two in the last two minutes", "Two", "Four", "As many as they like"], 0,
                   "Two in the first half and three in the second, and the last-two-minutes limit is the one that catches coaches out.",
                   .fiba),
        IQQuestion("q-timeout-who-fiba", .clock,
                   "In FIBA, who may call a timeout?",
                   ["The coach, at the scorer's table, when the clock is stopped", "Any player on the floor at any time",
                    "Only the captain", "Anyone on the bench at any time"], 0,
                   "In FIBA it is the coach's call through the table; in the NBA a player on the floor can call it too.",
                   .fiba),
        IQQuestion("q-14-reset", .clock,
                   "The defence fouls you in the front court with 6 seconds on the shot clock. What does it go to?",
                   ["14 seconds", "24 seconds", "It stays at 6", "20 seconds"], 0,
                   "A front-court defensive foul gives you 14 if you had less than that.", .bothBooks),
        IQQuestion("q-foul-to-give", .clock,
                   "Your team has a \"foul to give\" with 12 seconds left. What is it for?",
                   ["Fouling early to make them start their play again with less clock",
                    "Saving it for the last shot", "Getting a player out of the game",
                    "Stopping the clock after a basket"], 0,
                   "Before the bonus, a foul costs them time and a throw-in rather than free throws.", .convention),
        IQQuestion("q-quick-two", .clock,
                   "Down 2 with 9 seconds left and the ball, no timeouts. What do most coaches want?",
                   ["The best shot you can get, and a two that ties is fine",
                    "A three to win it outright every time", "Hold for the last second and shoot a three",
                    "Drive and try to get fouled only"], 0,
                   "A tie keeps you alive in overtime, so the shot you can actually make beats the one that wins it outright.",
                   .convention),
    ]

    /// The data checks, in the style of `IQScenarioLibrary.selfCheck()`: empty means it passed.
    static func selfCheck() -> [String] {
        var failures: [String] = []
        var seen = Set<String>()
        for q in all {
            if !seen.insert(q.id).inserted { failures.append("duplicate question id \(q.id)") }
            if q.options.count < 3 || q.options.count > 4 { failures.append("\(q.id): \(q.options.count) options") }
            if q.correctIndex < 0 || q.correctIndex >= q.options.count { failures.append("\(q.id): answer out of range") }
            if Set(q.options).count != q.options.count { failures.append("\(q.id): repeated option") }
            if q.rationale.isEmpty { failures.append("\(q.id): no rationale") }
            if q.question.isEmpty { failures.append("\(q.id): no question") }
        }
        if all.count < 40 { failures.append("only \(all.count) questions") }
        for topic in IQQuizTopic.allCases where !all.contains(where: { $0.topic == topic }) {
            failures.append("no questions on \(topic.title)")
        }
        return failures
    }
}
