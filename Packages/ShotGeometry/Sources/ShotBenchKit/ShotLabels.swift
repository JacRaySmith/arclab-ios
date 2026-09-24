// Ground-truth "is this window actually a shot" labels — a different thing from `Labels.swift`'s
// hand-stepped *release-time* labels. `docs/footage-2026-09-13/window_labels.json` records, for
// (ideally) every cached window, one of `shot` / `notShot` / `unsure`, made by an agent looking at
// ~4 tiled frames spanning the window (see that file's own `note`). This is what gives the bench a
// denominator: acceptance rate alone cannot say whether a refused window was a real shot the
// geometry got wrong or correctly-refused debris (a rebound, a pass, nothing at all).
//
// `unsure` is a real label, not a missing one — a window this agent could not call from four frames
// is excluded from precision/recall scoring, never counted as either outcome (see `PrecisionRecall.swift`).
import Foundation

public enum ShotLabelValue: String, Codable, Sendable {
    case shot
    case notShot
    case unsure
}

public struct WindowLabelEntry: Codable, Sendable {
    public var windowID: String
    public var clip: String
    public var label: ShotLabelValue
    public var reason: String?
    public init(windowID: String, clip: String, label: ShotLabelValue, reason: String? = nil) {
        self.windowID = windowID; self.clip = clip; self.label = label; self.reason = reason
    }
}

struct WindowLabelFile: Codable {
    var note: String?
    var clips: [String]?
    var labels: [WindowLabelEntry]
}

public struct LoadedWindowLabels: Sendable {
    public var sourcePath: String
    public var byWindowID: [String: WindowLabelEntry]
    public init(sourcePath: String, entries: [WindowLabelEntry]) {
        self.sourcePath = sourcePath
        // A duplicate windowID keeps the first entry — a malformed label file should not silently
        // pick a random winner.
        self.byWindowID = Dictionary(entries.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
    }
}

public struct WindowLabelLoadResult: Sendable {
    public var labels: LoadedWindowLabels?
    /// "scored" | "missing" | "unreadable"
    public var status: String
    public var detail: String?
    public var sourcePath: String
}

public enum WindowLabelLoader {
    /// Version-controlled, travels with the corpus — unlike release-time labels there is no
    /// Desktop-only fallback location; this file is meant to always live in the repo.
    public static var searchPaths: [String] {
        [FileManager.default.currentDirectoryPath + "/docs/footage-2026-09-13/window_labels.json"]
    }

    public static var defaultPath: String { searchPaths.first ?? "" }

    public static func load(path: String = defaultPath) -> WindowLabelLoadResult {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return WindowLabelLoadResult(labels: nil, status: "missing", detail: "no readable file at \(path)", sourcePath: path)
        }
        do {
            let decoded = try JSONDecoder().decode(WindowLabelFile.self, from: data)
            guard !decoded.labels.isEmpty else {
                return WindowLabelLoadResult(labels: nil, status: "unreadable", detail: "\(path) decoded but its \"labels\" array is empty", sourcePath: path)
            }
            return WindowLabelLoadResult(labels: LoadedWindowLabels(sourcePath: path, entries: decoded.labels), status: "scored", detail: nil, sourcePath: path)
        } catch {
            return WindowLabelLoadResult(labels: nil, status: "unreadable", detail: "\(path) does not match the expected shape: \(error)", sourcePath: path)
        }
    }
}
