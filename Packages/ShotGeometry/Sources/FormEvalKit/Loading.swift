// Loading exported `BodyShot` files back into the fit's own input type.
//
// Lifted from `Sources/BodyRefit/main.swift` deliberately rather than shared: BodyRefit is another
// track's tool and this harness must not change when that one does. The one thing both must agree on
// is `visionCamera`, the export↔Vision frame map, which is its own inverse.
import Foundation
import simd
import ShotGeometry

public enum BodyShotLoading {

    /// The export's camera frame (x right, y down, z forward) back into Vision's (x right, y up,
    /// z toward the camera) — the convention `BodyFrame.joints3D` is stored in.
    public static func visionCamera(_ j: BodyShotJoint3D) -> SIMD3<Double> { SIMD3(j.x, -j.y, -j.z) }

    /// Every `.json` under `path` (recursively when it is a directory), sorted by session then by
    /// the numeric shot id the phone writes, so the harness's row order is stable between runs.
    public static func files(at path: String) -> [URL] {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return [] }
        guard isDir.boolValue else { return url.pathExtension == "json" ? [url] : [] }
        var out: [URL] = []
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
        while let f = e?.nextObject() as? URL {
            if f.pathExtension == "json" { out.append(f) }
        }
        return out.sorted {
            let sa = $0.deletingLastPathComponent().lastPathComponent, sb = $1.deletingLastPathComponent().lastPathComponent
            if sa != sb { return sa < sb }
            let na = Int($0.deletingPathExtension().lastPathComponent) ?? Int.max
            let nb = Int($1.deletingPathExtension().lastPathComponent) ?? Int.max
            if na != nb { return na < nb }
            return $0.path < $1.path
        }
    }

    public static func timeline(_ shot: BodyShot, hfovOverride: Double? = nil) -> BodyTimeline {
        var frames: [BodyFrame] = []
        frames.reserveCapacity(shot.frames.count)
        for sf in shot.frames {
            var p2: [String: BodyPoint2D] = [:]
            for (name, p) in sf.points2D { p2[name] = BodyPoint2D(name: name, u: p.u, v: p.v, confidence: p.confidence) }
            var j3: [String: BodyJoint3D] = [:]
            for (name, j) in sf.joints3D {
                j3[name] = BodyJoint3D(name: name, position: .zero, cameraPosition: visionCamera(j), confidence: j.confidence)
            }
            let hands = sf.hands.map {
                BodyHandFrame(chirality: $0.chirality, role: $0.role, confidence: $0.confidence,
                              landmarks: $0.landmarks.mapValues { p in BodyPoint2D(name: "", u: p.u, v: p.v, confidence: p.confidence) })
            }
            frames.append(BodyFrame(frameIndex: sf.frameIndex, fileTime: sf.t_file, realTime: sf.t_real,
                                    joints3D: j3, points2D: p2, hands: hands))
        }
        let f = shot.source.format
        return BodyTimeline(frames: frames, timeScale: 1, imageWidth: f.w, imageHeight: f.h,
                            everyNthFrame: shot.timing.everyNthFrame, decodedFrames: frames.count,
                            analysedFrames: frames.count, wallSeconds: 0, notes: [])
    }

    /// The fit options the app itself would have used for this shot: its own intrinsics and, when the
    /// export says the scale came from a stated height, that height. Nothing is invented — an export
    /// whose scale was a population prior is refitted as one.
    public static func fitOptions(_ shot: BodyShot, hfovOverride: Double? = nil, heightOverride: Double? = nil) -> BodySkeletonOptions {
        let f = shot.source.format
        var o = BodySkeletonOptions(intrinsics: CameraIntrinsics(width: f.w, height: f.h,
                                                                horizontalFOVDegrees: hfovOverride ?? f.hfovDegrees))
        if let h = heightOverride ?? shot.skeleton.standingHeight.value,
           shot.skeleton.scaleProvenance == "statedHeight" || heightOverride != nil {
            o.scale = .statedHeight(metres: h)
        }
        return o
    }
}
