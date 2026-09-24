// Scoring the release detector against hand labels, when they exist.
//
// `~/Desktop/arclab-review/release_labels.json` is where the shooter's hand-stepped release times
// live (see docs/PIPELINE.md). Its shape, confirmed against the copy of this file kept in the repo
// at `docs/footage-2026-09-13/release_labels.json` (2026-09-24): a `labels` array of entries naming
// a *review* clip (a short export cut from the original session clip, e.g. "freethrow_t89.mov" cut
// from IMG_1765.mov) and a `release_file_s` — the release instant on that same raw file-time axis
// the original clip's `--rim`/`--time-scale` calibration uses. Matching therefore does not need the
// review clip's name at all: a cached window matches a label when the label's `release_file_s` falls
// inside that window's `[fileStart, fileEnd]` (both on the original clip's file-time axis), whatever
// clip the window came from. Convert to the "real seconds" the fit works in with `release_file_s /
// timeScale` (the corpus's clips bake a 30 fps timestamp onto 120 fps content; see docs/PIPELINE.md).
import Foundation

public struct ReleaseLabelEntry: Codable, Sendable {
    public var video: String
    public var window_start_file_s: Double
    public var release_between_frames: [Int]?
    public var release_file_s: Double
    public var pytrack_shot: String?
}

struct ReleaseLabelFile: Codable {
    var note: String?
    var labels: [ReleaseLabelEntry]
}

public struct LoadedLabels: Sendable {
    public var sourcePath: String
    public var entries: [ReleaseLabelEntry]

    /// The label (if any) whose release instant falls inside this window's analysed span, converted
    /// to the same "real seconds" the fit reports `releaseTime` in.
    public func matching(_ window: CachedWindow) -> (label: ReleaseLabelEntry, releaseReal: Double)? {
        guard window.timeScale > 0 else { return nil }
        guard let e = entries.first(where: { $0.release_file_s >= window.fileStart && $0.release_file_s <= window.fileEnd }) else { return nil }
        return (e, e.release_file_s / window.timeScale)
    }
}

public struct LabelLoadResult: Sendable {
    public var labels: LoadedLabels?
    /// "scored" | "missing" | "unreadable"
    public var status: String
    public var detail: String?
    public var sourcePath: String
}

public enum LabelLoader {
    public static var defaultPath: String { (NSString(string: "~/Desktop/arclab-review/release_labels.json")).expandingTildeInPath }

    public static func load(path: String = defaultPath) -> LabelLoadResult {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return LabelLoadResult(labels: nil, status: "missing", detail: "no readable file at \(path)", sourcePath: path)
        }
        do {
            let decoded = try JSONDecoder().decode(ReleaseLabelFile.self, from: data)
            guard !decoded.labels.isEmpty else {
                return LabelLoadResult(labels: nil, status: "unreadable", detail: "\(path) decoded but its \"labels\" array is empty", sourcePath: path)
            }
            return LabelLoadResult(labels: LoadedLabels(sourcePath: path, entries: decoded.labels), status: "scored", detail: nil, sourcePath: path)
        } catch {
            return LabelLoadResult(labels: nil, status: "unreadable", detail: "\(path) does not match the expected shape: \(error)", sourcePath: path)
        }
    }
}
