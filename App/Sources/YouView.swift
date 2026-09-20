import SwiftUI

/// **You** — the two things the app knows about the shooter, the two things it knows about the
/// phone, and where everything that used to clutter the home screen now lives
/// (`docs/IMPROVEMENTS-2026-09-16.md` §1.7 item 30).
///
/// The camera formats are shown read-only because they are a measurement, not a setting: the
/// horizontal field of view of the slo-mo format is the lens constant every distance in the geometry
/// is scaled by, and it is read off the device rather than assumed. Changing it here would mean
/// changing what the phone is.
struct YouView: View {
    var model: AnalysisModel
    var session: SessionModel
    var store: SessionStore

    @State private var hand = ShooterProfile.shootingHand
    @State private var camera: (device: String, formats: [ActivityLog.CameraFormat])?

    var body: some View {
        List {
            profileSection
            gamesSection
            cameraSection
            privacySection
            advancedSection
        }
        .navigationTitle("You")
        .task {
            camera = ActivityLog.cameraFormats()
            ActivityLog.shared.event("screen", ["name": "you",
                                                "height": ShooterProfile.heightCm,
                                                "hand": hand.rawValue])
        }
    }

    // MARK: The shooter

    private var profileSection: some View {
        Section {
            ShooterHeightRow()
            Picker("Shooting hand", selection: $hand) {
                ForEach(ShooterProfile.ShootingHand.allCases) { h in
                    Text(h.name).tag(h)
                }
            }
            .onChange(of: hand) { _, new in
                ShooterProfile.shootingHand = new
                ActivityLog.shared.event("profile.hand", ["hand": new.rawValue])
            }
            DisclosureGroup("Why the app asks") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(ShooterProfile.explanation)
                    Text(ShooterProfile.handPrompt)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .font(.subheadline)
        }
    }

    // MARK: Games (added 2026-09-19)

    /// The game log lives under You rather than Review because it is the one thing in the app the
    /// app did not measure: it is the shooter's own account of a game. Review is where measurements
    /// live, and putting a typed-in number in among them would blur the line the whole feature
    /// depends on.
    private var gamesSection: some View {
        Section {
            NavigationLink {
                GameLogView(store: store)
            } label: {
                Label("Games", systemImage: "list.clipboard")
            }
            Text("Log what you took and what went in after a game, and the app will put it beside your practice — with both counts, and with the smallest gap those counts could tell from luck.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Practice against games")
        } footer: {
            Text("This is the only place in ArcLab where a number comes from your memory rather than from the camera, and it is kept separate from the measured ones everywhere it appears.")
        }
    }

    // MARK: The phone

    @ViewBuilder private var cameraSection: some View {
        Section {
            if let camera {
                LabeledContent("Camera", value: camera.device)
                if camera.formats.isEmpty {
                    Text("No format on this camera records at 60 fps or more at 1280 px or wider. The geometry still works, but a 30 fps clip gives the fit far fewer points to sit on.")
                        .font(.footnote).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(camera.formats) { f in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.resolution).font(.subheadline.weight(.medium))
                            Text(f.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text("No back camera on this device, so nothing was read. Clips imported from the photo library are unaffected — their field of view is set by hand under Advanced.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("Why this matters") {
                Text("""
                     The horizontal field of view sets the scale of every distance the app measures: it turns pixels \
                     into metres against the rim's known 45.72 cm. These are read off the camera itself, once per \
                     launch, so a recording made in the app carries the right number without anyone typing it. A clip \
                     imported from the photo library carries no lens record, which is why its field of view is a field \
                     you fill in.
                     """)
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.subheadline)
        } header: {
            Text("This phone's camera")
        }
    }

    private var privacySection: some View {
        Section {
            Label("Everything runs on this phone; nothing is uploaded.", systemImage: "lock.shield")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Advanced

    private var feetEnabled: Binding<Bool> {
        Binding(get: { ShotBodyResult.feetEnabled },
                set: { UserDefaults.standard.set($0, forKey: "feet.enabled"); ActivityLog.shared.event("feet.enabled", ["on": $0]) })
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup("Advanced") {
                Toggle("Track the feet (heel and toes)", isOn: feetEnabled)
                Text("Adds a foot detector to the body pass: foot angle, roll and heel-first / toe-first contacts. Costs a little time per shot; off means those numbers are absent with a reason.")
                    .font(.caption).foregroundStyle(.secondary)
                NavigationLink {
                    AdvancedToolsView(model: model, session: session, store: store)
                } label: {
                    Label("Step-by-step tools", systemImage: "slider.horizontal.3")
                }
                NavigationLink {
                    ActivityLogTailView()
                } label: {
                    Label("What the app did", systemImage: "doc.text.magnifyingglass")
                }
                Text("The same measurements as the guided flow, one step at a time: timing and lens by hand, the rim, one chosen window, the raw Vision tracks. Nothing here is needed for a normal session.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.subheadline)
        }
    }
}

/// The last 200 lines of today's log, read-only. It is the app's own account of what it did — every
/// screen opened, every clip probed, every shot measured and every one refused, with its reason.
struct ActivityLogTailView: View {
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "Nothing logged yet today." : text)
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("What the app did")
        .navigationBarTitleDisplayMode(.inline)
        .task { text = ActivityLog.tail(lines: 200) }
    }
}
