import SwiftUI

/// The app shell: four tabs, four navigation stacks, one set of models.
///
/// `docs/IMPROVEMENTS-2026-09-16.md` §1.1 item 3. Until now everything lived in one
/// `NavigationStack` behind a home screen that was a grouped `List` of six `Start` rows — which made
/// "leave the analysis and look at last week" impossible, and is part of why the logs show analysis
/// cancelled 30 times in two days. Each tab keeps its own stack, so leaving one screen never unwinds
/// another.
///
/// The models are created once here and handed down, exactly as they were: `SessionStore` owns the
/// saved sessions on disk, `ShotDoctorModel` reads them, `AnalysisModel` and `SessionModel` hold the
/// clip being worked on, `PracticeStore` holds today's blocks. One of each — two `SessionStore`s
/// would be two versions of the truth.
struct ContentView: View {
    @State private var model = AnalysisModel()
    @State private var session = SessionModel()
    @State private var store: SessionStore
    @State private var doctor: ShotDoctorModel
    @State private var practice = PracticeStore()
    @State private var tab: AppTab = .shoot

    enum AppTab: Hashable { case shoot, review, learn, you }

    init() {
        let store = SessionStore()
        _store = State(initialValue: store)
        _doctor = State(initialValue: ShotDoctorModel(store: store))
        _tab = State(initialValue: ContentView.launchTab ?? .shoot)
    }

    /// `-tab review` on launch opens that tab. A tab bar cannot be tapped over USB, so this is the
    /// same kind of unattended hook as `-bench` in `BenchRunner`: it exists so a screenshot of every
    /// tab can be taken from the Mac without anyone touching the phone.
    private static var launchTab: AppTab? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-tab"), i + 1 < args.count else { return nil }
        switch args[i + 1] {
        case "shoot": return .shoot
        case "review": return .review
        case "learn": return .learn
        case "you": return .you
        default: return nil
        }
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Shoot", systemImage: "basketball.fill", value: AppTab.shoot) {
                NavigationStack {
                    TodayView(model: model, session: session, store: store, doctor: doctor, practice: practice)
                }
            }
            Tab("Review", systemImage: "chart.line.uptrend.xyaxis", value: AppTab.review) {
                NavigationStack {
                    ReviewView(store: store, doctor: doctor)
                }
            }
            Tab("Learn", systemImage: "graduationcap.fill", value: AppTab.learn) {
                NavigationStack {
                    LearnHubView(practice: practice, doctor: doctor, store: store)
                }
            }
            Tab("You", systemImage: "person.crop.circle", value: AppTab.you) {
                NavigationStack {
                    YouView(model: model, session: session, store: store)
                }
            }
        }
        .task {
            ActivityLog.logCameraFormats()
            BenchRunner.runIfRequested(model: model, session: session)
        }
    }
}

#Preview {
    ContentView()
}
