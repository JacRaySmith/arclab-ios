// ShotBenchKit — the cache format written by `TrajectoryProbe session --dump-windows` and read
// back here. Foundation + simd + ShotGeometry only (see `Packages/ShotGeometry/Package.swift`);
// no Vision, no AVFoundation, no video decode anywhere in this target.
//
// The JSON shape below is a *contract* with `Packages/ShotVideo/Sources/TrajectoryProbe/Probe.swift`
// (the `case "session":` block, `--dump-windows`). The field names must match exactly — there is
// no shared type between the two packages (ShotVideo depends on AVFoundation/Vision and this
// package must not), so both sides declare the shape independently and agree on it here.
import Foundation
import simd
import ShotGeometry

/// One ball detection as dumped: pixel coordinates split into `u`/`v` rather than `SIMD2<Double>`
/// so the cache file has no dependency on how either side encodes a SIMD type.
public struct CachedSample: Codable, Sendable, Equatable {
    public var t: Double
    public var u: Double
    public var v: Double
    public var diameterPx: Double?
    public init(t: Double, u: Double, v: Double, diameterPx: Double? = nil) {
        self.t = t; self.u = u; self.v = v; self.diameterPx = diameterPx
    }
    public var imageSample: ImageSample { ImageSample(t: t, uv: SIMD2(u, v), diameterPx: diameterPx) }
}

/// Everything needed to re-run `ShotAnalyzer.analyze` on one shot window without the source video.
public struct CachedWindow: Codable, Sendable, Equatable {
    /// Stable across runs and code changes: `"<clip stem>@<file start, 0.1 s, zero-padded>"`,
    /// e.g. `"IMG_1766@0455.6"`. Built once at dump time from the window's *arrival* file time
    /// (before the pre/post padding that turns an arrival into a decode window), so it does not
    /// move if the padding constants are retuned later.
    public var windowID: String
    /// Clip file name (not a path — the corpus is identified by name, e.g. `"IMG_1766.mov"`).
    public var clip: String
    /// `--spot` as passed to `session`; nil when not supplied.
    public var spot: String?
    public var samples: [CachedSample]
    /// Rim boundary points in pixels, exactly the `--rim` sidecar's `points` array.
    public var rimBoundary: [[Double]]
    public var rimDiameterUsed: Double
    public var width: Int
    public var height: Int
    public var hfovDegrees: Double
    public var timeScale: Double
    public var measuredFPS: Double
    /// The window's actual decoded/analysed span, in file-time seconds (post-padding). Useful for
    /// "does this window cover time T" questions (e.g. matching a hand-labelled release time);
    /// `windowID`'s anchor is a different, earlier instant on purpose (see above).
    public var fileStart: Double
    public var fileEnd: Double
    /// Pose-derived release time, in the same "real seconds" units as `samples[i].t`, when the
    /// session command found one. Nil means no pose override was used for this window.
    public var releaseTimeOverride: Double?
    public var dumpedAt: String

    public var rimBoundaryPoints: [SIMD2<Double>] { rimBoundary.map { SIMD2($0[0], $0[1]) } }
    public var intrinsics: CameraIntrinsics { CameraIntrinsics(width: width, height: height, horizontalFOVDegrees: hfovDegrees) }
}

/// One row of `manifest.json`: an index over the cache directory's window files, so a scan does
/// not need to open every file just to know what's there.
public struct ManifestEntry: Codable, Sendable, Equatable {
    public var windowID: String
    public var file: String
    public var clip: String
    public var spot: String?
    public var fileStart: Double
    public var sampleCount: Int
}

public enum CacheError: Error, CustomStringConvertible, Sendable {
    case noManifest(URL)
    case unreadableManifest(URL, String)
    case unreadableWindow(String, String)

    public var description: String {
        switch self {
        case .noManifest(let url): return "no manifest.json under \(url.path)"
        case .unreadableManifest(let url, let why): return "manifest.json at \(url.path) could not be read: \(why)"
        case .unreadableWindow(let file, let why): return "\(file) could not be read: \(why)"
        }
    }
}

public enum CacheLoader {
    public static func manifest(dir: URL) throws -> [ManifestEntry] {
        let url = dir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else { throw CacheError.noManifest(url) }
        do { return try JSONDecoder().decode([ManifestEntry].self, from: data) }
        catch { throw CacheError.unreadableManifest(url, "\(error)") }
    }

    /// Loads every window listed in the manifest. Windows that fail to decode are reported as
    /// errors, not silently skipped — a cache read must never quietly drop a window.
    public static func loadAll(dir: URL) throws -> (windows: [CachedWindow], errors: [String]) {
        let entries = try manifest(dir: dir)
        var windows: [CachedWindow] = []
        var errors: [String] = []
        windows.reserveCapacity(entries.count)
        for e in entries {
            let fileURL = dir.appendingPathComponent(e.file)
            guard let data = try? Data(contentsOf: fileURL) else { errors.append("\(e.file): could not read file"); continue }
            do { windows.append(try JSONDecoder().decode(CachedWindow.self, from: data)) }
            catch { errors.append("\(e.file): \(error)") }
        }
        return (windows, errors)
    }
}
