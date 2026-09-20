import AVKit
import PhotosUI
import SwiftUI

/// Game film review, v1 (1.4, 2026-09-19).
///
/// The honest shape of it: **you** tag the possessions, the app plays the film, keeps the tags, and
/// reads them back as review lines. Where the rim is in view and marked, the app also pre-seeds
/// *candidate* moments where a ball arrived at the rim, so scrubbing a long clip is less of a chore.
/// It never says who was open, who had the ball, or whether a read was right — see
/// `docs/DESIGN-FILM-REVIEW-2026-09-19.md` for what it would take to do that and why it is not
/// pretended here.

// MARK: - The way in: films you have, and importing one

struct FilmHomeView: View {
    @Bindable var store: FilmStore
    @State private var model = FilmModel()
    @State private var picked: PhotosPickerItem?
    @State private var openTagging = false

    var body: some View {
        List {
            if let err = store.loadError { Section { Text(err).foregroundStyle(.red) } }
            Section {
                PhotosPicker(selection: $picked, matching: .videos, photoLibrary: .shared()) {
                    Label("Import a game clip", systemImage: "film")
                }
                .disabled(model.analysis.isBusy)
                if model.analysis.isBusy {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Reading the clip").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if case .failed(let why) = model.analysis.phase {
                    Text(why).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("Your own game footage")
            } footer: {
                Text("Any frame rate, any length. You mark the possessions and what you did; the app keeps them and reads them back to you.")
            }

            Section {
                Text("What this does: plays your film, lets you tag each possession with one thumb, and turns your tags into a list you can read afterwards.")
                Text("What it does not do: it cannot tell who had the ball, who was open, or whether a pass was the right read. Nothing on the review screen is the app's opinion — every line is your own tag.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Be clear about this")
            }
            .font(.footnote)

            if store.films.isEmpty {
                Section { Text("No film saved yet.").font(.footnote).foregroundStyle(.secondary) }
            } else {
                Section("Saved film") {
                    ForEach(store.films) { f in
                        NavigationLink {
                            FilmTaggingView(store: store, reopening: f)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(f.title).font(.subheadline.weight(.semibold))
                                Text("\(f.myTags.count) of your possessions tagged · \(f.candidates.count) shot candidates")
                                    .font(.caption).foregroundStyle(.secondary)
                                if f.clipURL == nil {
                                    Text("The video file is gone from this phone, but your tags are still here.")
                                        .font(.caption2).foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in for i in offsets { store.delete(store.films[i].id) } }
                }
            }
        }
        .navigationTitle("Film review")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { ActivityLog.shared.event("screen", ["name": "film.home", "films": store.films.count]) }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            picked = nil
            model.importClip(item)
        }
        .onChange(of: model.analysis.phase) { _, phase in
            guard phase == .probed, model.film == nil else { return }
            model.clipIsReady(title: "Game " + Date().formatted(date: .abbreviated, time: .shortened))
            openTagging = true
        }
        .navigationDestination(isPresented: $openTagging) {
            FilmTaggingView(store: store, model: model)
        }
    }
}

// MARK: - The player, the timeline and the tag buttons

struct FilmTaggingView: View {
    @Bindable var store: FilmStore
    @State private var model: FilmModel
    /// Set when the screen was opened on a film saved earlier.
    private let reopening: FilmSession?
    @State private var title = ""
    @State private var showRim = false

    init(store: FilmStore, model: FilmModel) {
        self.store = store
        _model = State(initialValue: model)
        self.reopening = nil
    }

    init(store: FilmStore, reopening film: FilmSession) {
        self.store = store
        _model = State(initialValue: FilmModel())
        self.reopening = film
    }

    var body: some View {
        VStack(spacing: 0) {
            playerArea
            timeline
            Divider()
            tagControls
        }
        .navigationTitle(model.film?.title ?? "Film")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    if let f = model.film { FilmReviewSummaryView(film: f) }
                } label: {
                    Label("Review", systemImage: "list.bullet.rectangle")
                }
            }
        }
        .onAppear {
            if let reopening, model.film == nil { model.reopen(reopening) }
            title = model.film?.title ?? ""
            ActivityLog.shared.event("screen", ["name": "film.tagging", "tags": model.tags.count])
        }
        .onDisappear {
            model.save(to: store)
            model.closePlayer()
        }
        .sheet(isPresented: $showRim) {
            NavigationStack { RimMarkingView(model: model.analysis) }
        }
    }

    // MARK: Video

    @ViewBuilder private var playerArea: some View {
        if let player = model.player {
            VideoPlayer(player: player)
                .frame(height: 220)
                .background(Color.black)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "film.stack").font(.largeTitle).foregroundStyle(.secondary)
                Text("The video file is no longer on this phone. Your tags are below and still readable; import the clip again to scrub it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal)
            }
            .frame(height: 220)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemBackground))
        }
    }

    // MARK: Timeline

    private var timeline: some View {
        VStack(spacing: 4) {
            FilmTimelineStrip(duration: model.durationSeconds,
                              current: model.currentSeconds,
                              candidates: model.candidates.map(\.fileSeconds),
                              tags: model.tags.map(\.decisionSeconds),
                              onSeek: { model.seek(to: $0) })
                .frame(height: 34)
            HStack(spacing: 10) {
                Button { model.nudge(-1) } label: { Image(systemName: "gobackward.1") }
                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                }
                Button { model.nudge(1) } label: { Image(systemName: "goforward.1") }
                Text(FilmTag.clock(model.currentSeconds) + " / " + FilmTag.clock(model.durationSeconds))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if !model.candidates.isEmpty {
                    Text("\(model.candidates.count) candidates").font(.caption2).foregroundStyle(.orange)
                }
            }
            .buttonStyle(.bordered)
            .font(.footnote)
            .padding(.horizontal)
        }
        .padding(.vertical, 6)
    }

    // MARK: Tagging

    private var tagControls: some View {
        List {
            Section {
                Picker("Whose possession", selection: $model.who) {
                    ForEach(FilmActor.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Where from", selection: $model.range) {
                    ForEach(FilmRange.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                HStack {
                    Button {
                        model.markPossessionStart()
                    } label: {
                        Label(model.pendingStartSeconds == nil ? "Possession starts here" : "Start set at \(FilmTag.clock(model.pendingStartSeconds ?? 0))",
                              systemImage: "flag")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button { model.endPossessionHere() } label: {
                        Label("Ends here", systemImage: "flag.checkered")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.tags.isEmpty)
                }
                .font(.footnote)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(FilmDecision.allCases) { d in
                        Button { model.tag(d) } label: {
                            Label(d.name, systemImage: d.symbol)
                                .font(.footnote)
                                .frame(maxWidth: .infinity, minHeight: 40)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(d == .passedUpOpenShot ? .orange : .accentColor)
                        .disabled(model.film == nil)
                    }
                }
                .padding(.vertical, 2)
            } header: {
                Text("Tag what happened at this moment")
            } footer: {
                Text("Scrub to the moment the decision was made, then tap it. The tag is yours — the app is not deciding anything here.")
            }

            candidatesSection

            if !model.tags.isEmpty {
                Section("Your tags (\(model.tags.count))") {
                    ForEach(model.tags) { tag in
                        Button {
                            model.seek(to: tag.decisionSeconds)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tag.reviewLine).font(.footnote)
                                if let end = tag.possessionEndSeconds {
                                    Text("Possession \(FilmTag.clock(tag.possessionStartSeconds)) to \(FilmTag.clock(end))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        for i in offsets { model.removeTag(model.tags[i].id) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder private var candidatesSection: some View {
        Section {
            if model.scanning {
                HStack(spacing: 8) {
                    ProgressView(value: model.scanProgress)
                    Button("Stop") { model.cancelScan() }.font(.caption)
                }
                if let m = model.scanMessage { Text(m).font(.caption2).foregroundStyle(.secondary) }
            } else if let why = model.scanUnavailableReason {
                Text(why).font(.caption).foregroundStyle(.secondary)
                if model.analysis.clip != nil {
                    Button { showRim = true } label: { Label("Mark the rim", systemImage: "scope") }
                        .font(.footnote)
                }
            } else {
                Stepper(String(format: "Scan the first %.0f minutes", model.scanMinutes),
                        value: $model.scanMinutes, in: 1...30, step: 1)
                    .font(.footnote)
                Button { model.scanForCandidates() } label: {
                    Label("Find shot candidates", systemImage: "sparkle.magnifyingglass")
                }
                .font(.footnote)
            }
            if let note = model.film?.candidateNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if !model.candidates.isEmpty {
                ForEach(model.candidates) { c in
                    Button { model.seek(to: c.fileSeconds) } label: {
                        HStack {
                            Label("Candidate at \(c.timeText)", systemImage: "circle.dashed")
                            Spacer()
                            Text("\(c.descentCandidates) frames of descent").font(.caption2).foregroundStyle(.secondary)
                        }
                        .font(.footnote)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let err = model.scanError { Text(err).font(.caption).foregroundStyle(.red) }
        } header: {
            Text("Shot candidates (found by the app)")
        } footer: {
            Text("This is the one thing the app finds on its own: a ball arriving at the rim you marked. It is a place to scrub to, not a shot, and not a judgement.")
        }
    }
}

// MARK: - The strip

/// A scrub bar with two kinds of mark: shot candidates the app found, and tags you made.
struct FilmTimelineStrip: View {
    let duration: Double
    let current: Double
    let candidates: [Double]
    let tags: [Double]
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x: (Double) -> Double = { t in duration > 0 ? w * min(1, max(0, t / duration)) : 0 }
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4).fill(Color(.tertiarySystemFill))
                ForEach(Array(candidates.enumerated()), id: \.offset) { _, t in
                    Rectangle().fill(.orange).frame(width: 2, height: 14)
                        .offset(x: x(t), y: 2)
                }
                ForEach(Array(tags.enumerated()), id: \.offset) { _, t in
                    Rectangle().fill(.blue).frame(width: 2, height: 14)
                        .offset(x: x(t), y: 18)
                }
                Rectangle().fill(.primary).frame(width: 2)
                    .offset(x: x(current))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                guard duration > 0, w > 0 else { return }
                onSeek(duration * min(1, max(0, g.location.x / w)))
            })
        }
        .padding(.horizontal)
    }
}

// MARK: - Reading it back

struct FilmReviewSummaryView: View {
    let film: FilmSession

    var body: some View {
        List {
            Section {
                Text(film.summarySentence).font(.footnote)
            } header: {
                Text("This film")
            }

            let mine = film.myTags
            if mine.isEmpty {
                Section { Text("You have not tagged any of your own possessions yet.").font(.footnote).foregroundStyle(.secondary) }
            } else {
                Section("Your possessions (\(mine.count))") {
                    ForEach(mine) { tag in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tag.reviewLine).font(.footnote)
                            if let end = tag.possessionEndSeconds {
                                Text("Possession \(FilmTag.clock(tag.possessionStartSeconds)) to \(FilmTag.clock(end))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    ForEach(film.counts(for: .me), id: \.decision) { row in
                        LabeledContent(row.decision.name) {
                            Text("\(row.n)").monospacedDigit()
                        }
                        .font(.footnote)
                    }
                } header: {
                    Text("How often, out of \(mine.count)")
                } footer: {
                    Text("Counts of your own tags, with the total they came from. A handful of possessions is not a tendency — give it a few games before you read anything into it.")
                }
            }

            let theirs = film.tags.filter { $0.who == .teammate }
            if !theirs.isEmpty {
                Section("Teammates (\(theirs.count))") {
                    ForEach(theirs.sorted { $0.decisionSeconds < $1.decisionSeconds }) { tag in
                        Text(tag.reviewLine).font(.footnote)
                    }
                }
            }

            if !film.candidates.isEmpty || film.candidateNote != nil {
                Section {
                    if let note = film.candidateNote { Text(note).font(.caption).foregroundStyle(.secondary) }
                    Text("\(film.candidates.count) candidate\(film.candidates.count == 1 ? "" : "s") were found by the app. They are not counted with your tags above and say nothing about any decision.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text("What the app found on its own")
                }
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            ActivityLog.shared.event("film.review.shown", [
                "tags": film.tags.count, "mine": film.myTags.count,
                "candidates": film.candidates.count, "seconds": film.durationSeconds,
            ])
        }
    }
}
