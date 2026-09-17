import SwiftUI

/// "Your shot vs the profile": one row per measure, with what this block measured, where measured
/// shooters sat (population named, never a target), the evidence grade behind that range, and one
/// association-only reading. Rows the block could not measure say why. Below the 30-shot floor the
/// whole table carries the preview tag and concludes nothing.
struct ShotProfileView: View {
    let profile: ShotProfile
    @State private var expanded: Set<Int> = []

    var body: some View {
        Section {
            if let tag = profile.previewTag {
                Label(tag, systemImage: "hourglass").font(.caption).foregroundStyle(.orange)
            }
            ForEach(profile.rows) { row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.metric).font(.subheadline.bold())
                        Spacer()
                        gradeBadge(row.grade)
                    }
                    if let yours = row.yours {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("Yours").font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                            Text(yours).font(.caption.monospacedDigit())
                        }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("Yours").font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                            Text(row.unavailableReason ?? "not measured").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Measured").font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                        Text(row.profile).font(.caption)
                    }
                    Text(row.reading).font(.caption).foregroundStyle(row.yours == nil ? .secondary : .primary)
                    if expanded.contains(row.id) {
                        Text(row.source).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
                }
            }
        } header: {
            Text("Your shot vs measured shooters")
        } footer: {
            Text(profile.note + " Tap a row for its source. A = peer-reviewed measurement on skilled shooters or exact geometry; B = smaller or indirect study; C = coaching consensus; D = opinion or untested. \"Measured\" is where a named population sat, not a target.")
        }
    }

    private func gradeBadge(_ g: EvidenceGrade) -> some View {
        Text(g.letter)
            .font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color(g).opacity(0.18), in: Capsule())
            .foregroundStyle(color(g))
    }

    private func color(_ g: EvidenceGrade) -> Color {
        switch g {
        case .a: return .green
        case .b: return .teal
        case .c: return .orange
        case .d: return .secondary
        }
    }
}
