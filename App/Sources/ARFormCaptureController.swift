import ARKit
import AVFoundation
import Foundation
import ShotGeometry
import simd
import UIKit

/// The ARKit body-tracking experiment (`docs/research/arkit-body-tracking-spike-2026-09-15.md`): can the
/// rear camera's `ARBodyTrackingConfiguration` give a metric 3-D skeleton of a shooting motion with no rim
/// and no stated height? This owns the `ARSession`, keeps the live readout the screen shows, records every
/// `ARFrame` while "Record" is on and files two JSON documents under `Documents/ArcLab/arbody/` at stop:
/// the raw ARKit log (`<date>.json`) and a BodyShot-compatible export (`<date>.bodyshot.json`).
///
/// Everything measured here is *reported*, never assumed: detection is counted per frame, the scale factor
/// is what ARKit says (`estimatedScaleFactor`, only meaningful with automatic scale estimation on), and a
/// quantity the spike cannot produce (release time, phases, angles) is written as unavailable with a reason.
/// Nothing leaves the phone; ARKit runs on device with no network.
@MainActor
@Observable
final class ARFormCaptureController {
    enum Permission: Sendable { case unknown, authorized, denied, restricted }

    enum Status: Equatable {
        case idle
        /// This device or build cannot run body tracking (the Simulator, or `isSupported == false`).
        case unsupported(String)
        case starting
        case running
        case recording
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var cameraPermission: Permission = .unknown

    // MARK: Live readout

    private(set) var bodyDetected = false
    private(set) var anchorIsTracked = false
    private(set) var trackedJointCount = 0
    private(set) var jointCount = 0
    private(set) var scaleFactor: Float?
    private(set) var anchorUpdatesPerSecond = 0.0
    private(set) var framesPerSecond = 0.0
    private(set) var secondsSinceStart = 0.0
    /// Seconds from session start to the first `ARBodyAnchor`; nil until one is seen (the iOS 26 question).
    private(set) var firstBodySeenAfter: Double?
    private(set) var recordedFrames = 0
    private(set) var recordedDetected = 0
    private(set) var recordingSeconds = 0.0
    private(set) var lastResult: String?
    private(set) var videoFormatDescription = "—"
    /// Draw the skeleton at `model × estimatedScaleFactor` (the metric hypothesis) or the raw rig size.
    /// Whichever sits on the person is the one that is right; the readout says which is on.
    var drawScaled = true

    struct OverlayJoint: Equatable { var point: CGPoint; var tracked: Bool }
    struct OverlayBone: Equatable { var a: CGPoint; var b: CGPoint; var tracked: Bool }
    private(set) var overlayJoints: [OverlayJoint] = []
    private(set) var overlayBones: [OverlayBone] = []

    /// The camera view. Created lazily so the Simulator / unsupported path never touches ARKit.
    private(set) var arView: ARSCNView?

    // MARK: Private state

    private var proxy: SessionProxy?
    private var sessionStart: Double?
    private var frameTimestamps: [Double] = []
    private var anchorUpdateTimes: [Double] = []
    private var frameCounter = 0
    private var bodyWasDetected = false

    private var recording = false
    private var recordStart: Double?
    private var rawFrames: [RawFrame] = []
    private var meta = SessionMeta()

    /// One `ARFrame`, reduced to what the analysis needs. Joint transforms are `ARSkeleton3D.jointModelTransforms`
    /// (relative to the anchor, column-major) for the joints `isJointTracked` reports true.
    struct RawFrame: Sendable {
        var timestamp: Double
        var hasBody: Bool
        var isTracked: Bool
        var scale: Float?
        var anchor: simd_float4x4?
        var jointIndices: [Int]
        var jointTransforms: [simd_float4x4]
    }

    struct SessionMeta: Sendable {
        var jointNames: [String] = []
        var parentIndices: [Int] = []
        var imageWidth = 0, imageHeight = 0
        var fx: Float = 0, fy: Float = 0, cx: Float = 0, cy: Float = 0
        var videoFPS = 0
        var firstBodySeenAfter: Double?
    }

    // MARK: Lifecycle

    /// Checks support, asks for the camera, starts the session. Safe to call again on every appear.
    func begin() async {
        #if targetEnvironment(simulator)
        status = .unsupported("ARKit body tracking does not run in the Simulator. Run ArcLab on the iPhone.")
        ActivityLog.shared.event("arbody.start", ["supported": false, "reason": "simulator"])
        return
        #else
        if case .unsupported = status { return }
        guard ARBodyTrackingConfiguration.isSupported else {
            status = .unsupported("ARBodyTrackingConfiguration.isSupported is false on this device (iOS \(UIDevice.current.systemVersion)).")
            ActivityLog.shared.event("arbody.start", ["supported": false, "reason": "isSupported false", "system": UIDevice.current.systemVersion])
            return
        }
        cameraPermission = await ARFormCaptureController.requestCamera()
        guard cameraPermission == .authorized else {
            status = .idle
            ActivityLog.shared.event("arbody.start", ["supported": true, "camera": "\(cameraPermission)"])
            return
        }
        if arView == nil {
            let view = ARSCNView(frame: .zero)
            view.automaticallyUpdatesLighting = false
            view.rendersCameraGrain = false
            let p = SessionProxy()
            p.controller = self
            view.session.delegate = p          // delegateQueue nil → main queue; the proxy relies on that.
            proxy = p
            arView = view
        }
        run()
        #endif
    }

    private func run() {
        guard let arView else { return }
        let config = ARBodyTrackingConfiguration()
        config.automaticSkeletonScaleEstimationEnabled = true   // off by default: without it the scale is always 1
        config.isAutoFocusEnabled = true
        if let best = ARBodyTrackingConfiguration.supportedVideoFormats.max(by: { a, b in
            a.framesPerSecond != b.framesPerSecond ? a.framesPerSecond < b.framesPerSecond
                : a.imageResolution.width < b.imageResolution.width }) {
            config.videoFormat = best
        }
        meta.videoFPS = config.videoFormat.framesPerSecond
        meta.imageWidth = Int(config.videoFormat.imageResolution.width)
        meta.imageHeight = Int(config.videoFormat.imageResolution.height)
        videoFormatDescription = "\(meta.imageWidth)×\(meta.imageHeight) @ \(meta.videoFPS)"
        let def = ARSkeletonDefinition.defaultBody3D
        meta.jointNames = def.jointNames
        meta.parentIndices = def.parentIndices
        jointCount = def.jointCount
        sessionStart = nil
        frameTimestamps = []
        anchorUpdateTimes = []
        firstBodySeenAfter = nil
        bodyWasDetected = false
        status = .starting
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        ActivityLog.shared.event("arbody.start", [
            "supported": true, "system": UIDevice.current.systemVersion, "joints": def.jointCount,
            "format": videoFormatDescription, "scaleEstimation": true,
            "formats": ARBodyTrackingConfiguration.supportedVideoFormats.map { "\(Int($0.imageResolution.width))x\(Int($0.imageResolution.height))@\($0.framesPerSecond)" }.joined(separator: "; "),
        ])
    }

    /// Pauses the session; a running ARSession owns the camera and is the most expensive thing to leave on.
    func end() {
        if recording { stopRecording() }
        arView?.session.pause()
        if case .unsupported = status { return }
        status = .idle
        ActivityLog.shared.event("arbody.end", ["frames": frameCounter, "firstBodySeenAfter": firstBodySeenAfter])
    }

    private static func requestCamera() async -> Permission {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video) ? .authorized : .denied
        @unknown default: return .denied
        }
    }

    // MARK: Recording

    func toggleRecording() {
        recording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        rawFrames.removeAll(keepingCapacity: true)
        recordStart = nil
        recordedFrames = 0
        recordedDetected = 0
        recordingSeconds = 0
        recording = true
        status = .recording
        ActivityLog.shared.event("arbody.record.start", ["format": videoFormatDescription])
    }

    private func stopRecording() {
        recording = false
        status = .running
        let frames = rawFrames
        rawFrames = []
        var m = meta
        m.firstBodySeenAfter = firstBodySeenAfter
        let device = UIDevice.current.model + " / iOS " + UIDevice.current.systemVersion
        let build = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
            + " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?") + ")"
        guard !frames.isEmpty else {
            lastResult = "Nothing recorded"
            ActivityLog.shared.event("arbody.recorded", ["frames": 0])
            return
        }
        let summary = ARBodyRecording.summarise(frames)
        lastResult = String(format: "%d frames, %.0f%% detected, %.1f joints, scale %@",
                            summary.frames, summary.detectedFraction * 100, summary.meanTrackedJoints,
                            summary.scaleMean.map { String(format: "%.3f ±%.1f%%", $0, summary.scaleSpreadPercent ?? 0) } ?? "n/a")
        let stamp = ARBodyRecording.fileStamp(Date())
        Task.detached(priority: .utility) {
            let dir = ARBodyRecording.directory
            let rawURL = dir.appendingPathComponent(stamp + ".json")
            let shotURL = dir.appendingPathComponent(stamp + ".bodyshot.json")
            var fields: [String: Any?] = [
                "frames": summary.frames, "detectedFraction": summary.detectedFraction,
                "meanTrackedJoints": summary.meanTrackedJoints, "scale": summary.scaleMean,
                "scaleMin": summary.scaleMin, "scaleMax": summary.scaleMax, "scaleSpreadPercent": summary.scaleSpreadPercent,
                "seconds": summary.seconds, "fps": summary.fps, "firstBodySeenAfter": m.firstBodySeenAfter,
                "path": rawURL.path,
            ]
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let raw = try ARBodyRecording.rawLog(frames: frames, meta: m, device: device, build: build, recordedAt: stamp)
                try raw.write(to: rawURL, options: .atomic)
                fields["bytes"] = raw.count
            } catch {
                fields["error"] = "\(error)"
            }
            do {
                let shot = try ARBodyRecording.bodyShot(frames: frames, meta: m, device: device, build: build, summary: summary)
                let data = try shot.encoded()
                _ = try BodyShot.decode(data)       // the reader must accept what we wrote, or the export is worthless
                try data.write(to: shotURL, options: .atomic)
                fields["bodyShotBytes"] = data.count
                fields["bodyShotFrames"] = shot.frames.count
                fields["bodyShotPath"] = shotURL.path
            } catch {
                fields["bodyShotError"] = "\(error)"
            }
            ActivityLog.shared.event("arbody.recorded", fields)
        }
    }

    // MARK: Frame handling (main queue, from the session delegate)

    fileprivate func handle(frame: ARFrame) {
        let t = frame.timestamp
        if sessionStart == nil {
            sessionStart = t
            if status == .starting { status = .running }
            let k = frame.camera.intrinsics
            meta.fx = k.columns.0.x; meta.fy = k.columns.1.y; meta.cx = k.columns.2.x; meta.cy = k.columns.2.y
            meta.imageWidth = Int(frame.camera.imageResolution.width)
            meta.imageHeight = Int(frame.camera.imageResolution.height)
        }
        frameCounter += 1
        frameTimestamps.append(t)
        if frameTimestamps.count > 60 { frameTimestamps.removeFirst(frameTimestamps.count - 60) }
        anchorUpdateTimes.removeAll { $0 < t - 1 }

        let body = frame.anchors.lazy.compactMap { $0 as? ARBodyAnchor }.first
        var raw = RawFrame(timestamp: t, hasBody: false, isTracked: false, scale: nil, anchor: nil, jointIndices: [], jointTransforms: [])
        var joints: [OverlayJoint] = []
        var bones: [OverlayBone] = []
        var trackedCount = 0

        if let body {
            let skeleton = body.skeleton
            let transforms = skeleton.jointModelTransforms
            let scale = Float(body.estimatedScaleFactor)
            let drawScale: Float = drawScaled ? scale : 1
            let orientation = arView?.window?.windowScene?.interfaceOrientation ?? .landscapeRight
            let viewport = arView?.bounds.size ?? .zero
            var projected: [CGPoint?] = Array(repeating: nil, count: transforms.count)
            var tracked: [Bool] = Array(repeating: false, count: transforms.count)
            for i in transforms.indices {
                let isTracked = skeleton.isJointTracked(i)
                tracked[i] = isTracked
                if isTracked {
                    trackedCount += 1
                    raw.jointIndices.append(i)
                    raw.jointTransforms.append(transforms[i])
                }
                guard viewport.width > 0 else { continue }
                let local = transforms[i].columns.3
                let world = body.transform * SIMD4<Float>(local.x * drawScale, local.y * drawScale, local.z * drawScale, 1)
                let p = frame.camera.projectPoint(SIMD3<Float>(world.x, world.y, world.z), orientation: orientation, viewportSize: viewport)
                if p.x.isFinite, p.y.isFinite { projected[i] = p }
            }
            for i in transforms.indices {
                guard let p = projected[i] else { continue }
                joints.append(OverlayJoint(point: p, tracked: tracked[i]))
                let parent = i < meta.parentIndices.count ? meta.parentIndices[i] : -1
                if parent >= 0, let q = projected[parent] {
                    bones.append(OverlayBone(a: p, b: q, tracked: tracked[i] && tracked[parent]))
                }
            }
            raw.hasBody = true
            raw.isTracked = body.isTracked
            raw.scale = scale
            raw.anchor = body.transform
            if firstBodySeenAfter == nil, let s = sessionStart {
                firstBodySeenAfter = t - s
                ActivityLog.shared.event("arbody.body.first", ["after": t - s, "tracked": trackedCount, "scale": Double(scale)])
            }
            if !bodyWasDetected { bodyWasDetected = true }
        } else if bodyWasDetected {
            bodyWasDetected = false
            ActivityLog.shared.event("arbody.body.lost", ["after": sessionStart.map { t - $0 }])
        }

        overlayJoints = joints
        overlayBones = bones

        if recording {
            if recordStart == nil { recordStart = t }
            rawFrames.append(raw)
        }

        // The numeric readout at ~10 Hz; the overlay above updates every frame.
        if frameCounter % 6 == 0 {
            bodyDetected = body != nil
            anchorIsTracked = body?.isTracked ?? false
            trackedJointCount = trackedCount
            scaleFactor = body.map { Float($0.estimatedScaleFactor) }
            anchorUpdatesPerSecond = Double(anchorUpdateTimes.count)
            if let first = frameTimestamps.first, frameTimestamps.count > 1, t > first {
                framesPerSecond = Double(frameTimestamps.count - 1) / (t - first)
            }
            secondsSinceStart = sessionStart.map { t - $0 } ?? 0
            if recording {
                recordedFrames = rawFrames.count
                recordedDetected = rawFrames.reduce(0) { $0 + ($1.hasBody ? 1 : 0) }
                recordingSeconds = recordStart.map { t - $0 } ?? 0
            }
        }
    }

    fileprivate func handle(anchorUpdates anchors: [ARAnchor]) {
        guard anchors.contains(where: { $0 is ARBodyAnchor }) else { return }
        anchorUpdateTimes.append(frameTimestamps.last ?? 0)
    }

    fileprivate func handle(failure error: Error) {
        status = .failed(error.localizedDescription)
        ActivityLog.shared.event("arbody.failed", ["error": "\(error)"])
    }
}

/// `ARSessionDelegate` is called on `session.delegateQueue`, which is the main queue unless set — so the
/// hop to the controller is an assertion, not a dispatch, and the non-Sendable `ARFrame` never crosses an
/// isolation boundary. Frames are consumed inside the callback and never retained.
@MainActor
private final class SessionProxy: NSObject, ARSessionDelegate {
    weak var controller: ARFormCaptureController?

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        MainActor.assumeIsolated { controller?.handle(frame: frame) }
    }
    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        MainActor.assumeIsolated { controller?.handle(anchorUpdates: anchors) }
    }
    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        MainActor.assumeIsolated { controller?.handle(failure: error) }
    }
}

// MARK: - Files: the raw log and the BodyShot export

enum ARBodyRecording {
    static var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ArcLab/arbody", isDirectory: true)
    }

    static func fileStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return f.string(from: date)
    }

    struct Summary: Sendable {
        var frames: Int
        var detected: Int
        var detectedFraction: Double
        var meanTrackedJoints: Double
        var scaleMean: Double?, scaleMin: Double?, scaleMax: Double?, scaleSpreadPercent: Double?
        var seconds: Double
        var fps: Double
    }

    static func summarise(_ frames: [ARFormCaptureController.RawFrame]) -> Summary {
        let detected = frames.filter(\.hasBody)
        let scales = detected.compactMap { $0.scale.map(Double.init) }
        let mean = scales.isEmpty ? nil : scales.reduce(0, +) / Double(scales.count)
        let spread: Double? = {
            guard let mean, mean > 0, let lo = scales.min(), let hi = scales.max() else { return nil }
            return (hi - lo) / mean * 100
        }()
        let seconds = (frames.last?.timestamp ?? 0) - (frames.first?.timestamp ?? 0)
        return Summary(
            frames: frames.count, detected: detected.count,
            detectedFraction: frames.isEmpty ? 0 : Double(detected.count) / Double(frames.count),
            meanTrackedJoints: detected.isEmpty ? 0 : Double(detected.reduce(0) { $0 + $1.jointIndices.count }) / Double(detected.count),
            scaleMean: mean, scaleMin: scales.min(), scaleMax: scales.max(), scaleSpreadPercent: spread,
            seconds: seconds, fps: frames.count > 1 && seconds > 0 ? Double(frames.count - 1) / seconds : 0)
    }

    // MARK: Raw ARKit log

    struct RawLog: Encodable {
        struct Frame: Encodable {
            var t: Double
            var hasBody: Bool
            var isTracked: Bool
            var scale: Float?
            var anchorTransform: [Float]?
            var trackedJointCount: Int
            /// ARKit joint name → `jointModelTransforms[i]` as 16 column-major floats (anchor space, unscaled rig).
            var joints: [String: [Float]]
        }
        var version = 1
        var kind = "arkit.bodyTracking.raw"
        var recordedAt: String
        var device: String
        var build: String
        var jointNames: [String]
        var parentIndices: [Int]
        var imageWidth: Int, imageHeight: Int
        var intrinsics: [String: Float]
        var videoFPS: Int
        var firstBodySeenAfter: Double?
        var notes: [String]
        var frames: [Frame]
    }

    static func flat(_ m: simd_float4x4) -> [Float] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    static func rawLog(frames: [ARFormCaptureController.RawFrame], meta: ARFormCaptureController.SessionMeta,
                       device: String, build: String, recordedAt: String) throws -> Data {
        let t0 = frames.first?.timestamp ?? 0
        let rows = frames.map { f in
            var joints: [String: [Float]] = [:]
            for (k, i) in f.jointIndices.enumerated() where i < meta.jointNames.count {
                joints[meta.jointNames[i]] = flat(f.jointTransforms[k])
            }
            return RawLog.Frame(t: f.timestamp - t0, hasBody: f.hasBody, isTracked: f.isTracked, scale: f.scale,
                                anchorTransform: f.anchor.map(flat), trackedJointCount: f.jointIndices.count, joints: joints)
        }
        let log = RawLog(
            recordedAt: recordedAt, device: device, build: build,
            jointNames: meta.jointNames, parentIndices: meta.parentIndices,
            imageWidth: meta.imageWidth, imageHeight: meta.imageHeight,
            intrinsics: ["fx": meta.fx, "fy": meta.fy, "cx": meta.cx, "cy": meta.cy],
            videoFPS: meta.videoFPS, firstBodySeenAfter: meta.firstBodySeenAfter,
            notes: [
                "t: seconds since the first recorded ARFrame (ARFrame.timestamp differences).",
                "joints: only joints with isJointTracked == true; transforms are ARSkeleton3D.jointModelTransforms (relative to anchorTransform), column-major.",
                "scale: ARBodyAnchor.estimatedScaleFactor with automaticSkeletonScaleEstimationEnabled = true; metric hypothesis: metres = model translation × scale, then anchorTransform.",
                "world frame: ARKit world, y up (gravity), origin where the session started.",
            ],
            frames: rows)
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(log)
    }

    // MARK: Joint mapping (ARKit `ARSkeletonDefinition.defaultBody3D` names → docs/BIOMETRIC-SCHEMA.md §1)

    /// `fitted` is the `fitted3D` key, `seen` the key the per-frame `seen` dictionary uses (the
    /// `SceneBodyJoints.seenKey` convention: centerHead ↔ nose, centerShoulder ↔ neck).
    struct JointMapping: Sendable { let arkit: String; let fitted: String; let seen: String }

    static let jointMap: [JointMapping] = [
        .init(arkit: "hips_joint", fitted: "root", seen: "root"),
        .init(arkit: "spine_7_joint", fitted: "spine", seen: "spine"),
        .init(arkit: "neck_1_joint", fitted: "centerShoulder", seen: "neck"),
        .init(arkit: "head_joint", fitted: "centerHead", seen: "nose"),
        .init(arkit: "left_eye_joint", fitted: "leftEye", seen: "leftEye"),
        .init(arkit: "right_eye_joint", fitted: "rightEye", seen: "rightEye"),
        // ARKit's rig has two joints per shoulder: `*_shoulder_1_joint` (clavicle root, next to spine_7) and
        // `*_arm_joint` (the humeral head). The schema's shoulder is the humeral head, so `*_arm_joint` is
        // used; the clavicle stays in the raw log. Verify on the phone: |shoulder_1 → arm| should be ~0.15 m.
        .init(arkit: "left_arm_joint", fitted: "leftShoulder", seen: "leftShoulder"),
        .init(arkit: "right_arm_joint", fitted: "rightShoulder", seen: "rightShoulder"),
        .init(arkit: "left_forearm_joint", fitted: "leftElbow", seen: "leftElbow"),
        .init(arkit: "right_forearm_joint", fitted: "rightElbow", seen: "rightElbow"),
        .init(arkit: "left_hand_joint", fitted: "leftWrist", seen: "leftWrist"),
        .init(arkit: "right_hand_joint", fitted: "rightWrist", seen: "rightWrist"),
        .init(arkit: "left_upLeg_joint", fitted: "leftHip", seen: "leftHip"),
        .init(arkit: "right_upLeg_joint", fitted: "rightHip", seen: "rightHip"),
        .init(arkit: "left_leg_joint", fitted: "leftKnee", seen: "leftKnee"),
        .init(arkit: "right_leg_joint", fitted: "rightKnee", seen: "rightKnee"),
        .init(arkit: "left_foot_joint", fitted: "leftAnkle", seen: "leftAnkle"),
        .init(arkit: "right_foot_joint", fitted: "rightAnkle", seen: "rightAnkle"),
        // First source with toes (Vision has none; MediaPipe is not in the app). `*_toesEnd_joint` is the tip.
        .init(arkit: "left_toes_joint", fitted: "leftFootIndex", seen: "leftFootIndex"),
        .init(arkit: "right_toes_joint", fitted: "rightFootIndex", seen: "rightFootIndex"),
    ]

    /// Bones whose lengths are reported (ARKit's rig is rigid: they are the rig's lengths × the uniform scale).
    static let bones: [(String, String)] = [
        ("root", "spine"), ("spine", "centerShoulder"), ("centerShoulder", "centerHead"),
        ("centerShoulder", "leftShoulder"), ("centerShoulder", "rightShoulder"),
        ("leftShoulder", "leftElbow"), ("rightShoulder", "rightElbow"), ("leftElbow", "leftWrist"), ("rightElbow", "rightWrist"),
        ("root", "leftHip"), ("root", "rightHip"), ("leftHip", "leftKnee"), ("rightHip", "rightKnee"),
        ("leftKnee", "leftAnkle"), ("rightKnee", "rightAnkle"), ("leftAnkle", "leftFootIndex"), ("rightAnkle", "rightFootIndex"),
    ]

    // MARK: BodyShot export

    /// The schema's body frame from the ARKit world frame: origin at the hips in the first detected frame,
    /// z = world up (ARKit's +y, gravity-aligned), x = the shooter's facing direction in that frame (up ×
    /// (rightShoulder − leftShoulder)) because no rim is known, y = z × x. Scale: metres by the ARKit
    /// hypothesis `model translation × estimatedScaleFactor`. Everything the spike does not measure is
    /// unavailable with a reason; `timing.releaseRealTime` is a non-optional Double in the schema, so it
    /// carries −1 and a warning rather than a made-up release.
    static func bodyShot(frames: [ARFormCaptureController.RawFrame], meta: ARFormCaptureController.SessionMeta,
                         device: String, build: String, summary: Summary) throws -> BodyShot {
        func r(_ x: Double, _ d: Int = 4) -> Double { let p = pow(10.0, Double(d)); return (x * p).rounded() / p }
        let nameToIndex = Dictionary(uniqueKeysWithValues: meta.jointNames.enumerated().map { ($1, $0) })
        var mappings: [(map: JointMapping, index: Int)] = []
        var unmapped: [String] = []
        for m in jointMap {
            if let i = nameToIndex[m.arkit] { mappings.append((m, i)) } else { unmapped.append(m.arkit) }
        }

        /// Metric world position of joint `i` in `f`, or nil if it was not tracked in that frame.
        func world(_ f: ARFormCaptureController.RawFrame, _ i: Int) -> SIMD3<Double>? {
            guard let anchor = f.anchor, let scale = f.scale, let k = f.jointIndices.firstIndex(of: i) else { return nil }
            let l = f.jointTransforms[k].columns.3
            let w = anchor * SIMD4<Float>(l.x * scale, l.y * scale, l.z * scale, 1)
            return SIMD3<Double>(Double(w.x), Double(w.y), Double(w.z))
        }

        let t0 = frames.first?.timestamp ?? 0
        let detected = frames.filter(\.hasBody)
        var warnings: [String] = [
            "timing.releaseRealTime = -1: the ARKit spike detects no release, set, dip or follow-through",
            "feet/toes come from ARKit (the first source that has them); heels are absent (ARKit has no heel joint)",
            "scale is ARKit's estimatedScaleFactor (a whole-body scale from the rig), not a stated height",
        ]
        var notes: [String] = [
            "source: ARBodyTrackingConfiguration, rear camera, automaticSkeletonScaleEstimationEnabled = true",
            "joint mapping: " + jointMap.map { "\($0.arkit)→\($0.fitted)" }.joined(separator: ", "),
        ]
        if !unmapped.isEmpty { warnings.append("ARKit joint names not found in this rig: " + unmapped.joined(separator: ", ")) }

        // Body frame from the first detected frame.
        let rootIndex = nameToIndex["hips_joint"]
        let lsIndex = nameToIndex["left_arm_joint"], rsIndex = nameToIndex["right_arm_joint"]
        let up = SIMD3<Double>(0, 1, 0)
        var origin = SIMD3<Double>(0, 0, 0)
        var forward = SIMD3<Double>(1, 0, 0)
        var facingNote = "x = ARKit world +x (no frame had the hips and both shoulders tracked)"
        if let f = detected.first(where: { f in rootIndex.flatMap { world(f, $0) } != nil }), let ri = rootIndex, let o = world(f, ri) {
            origin = o
            if let li = lsIndex, let rsi = rsIndex, let l = world(f, li), let rr = world(f, rsi) {
                var shoulder = rr - l
                shoulder.y = 0
                let fwd = simd_cross(up, shoulder)
                if simd_length(fwd) > 1e-6 {
                    forward = simd_normalize(fwd)
                    facingNote = "x = shooter facing at the first detected frame (up × (rightShoulder − leftShoulder)); the rim is unknown"
                }
            }
        } else {
            warnings.append("no frame had a tracked hips_joint: body-frame origin is the ARKit world origin")
        }
        let zAxis = up, xAxis = forward, yAxis = simd_cross(zAxis, xAxis)
        func toBody(_ p: SIMD3<Double>) -> SIMD3<Double> {
            let d = p - origin
            return SIMD3(simd_dot(d, xAxis), simd_dot(d, yAxis), simd_dot(d, zAxis))
        }

        // Frames.
        var out: [BodyShotFrame] = []
        var seenCounts: [String: Int] = [:]
        var lengths: [String: [Double]] = [:]
        for (n, f) in frames.enumerated() {
            var fitted: [String: BodyShotFitted3D] = [:]
            var seen: [String: Bool] = [:]
            var bodyPos: [String: SIMD3<Double>] = [:]
            for (m, i) in mappings {
                if f.hasBody, let w = world(f, i) {
                    let b = toBody(w)
                    fitted[m.fitted] = BodyShotFitted3D(x: r(b.x), y: r(b.y), z: r(b.z))
                    seen[m.seen] = true
                    seenCounts[m.seen, default: 0] += 1
                    bodyPos[m.fitted] = b
                } else {
                    seen[m.seen] = false
                }
            }
            for (a, b) in bones {
                if let pa = bodyPos[a], let pb = bodyPos[b] { lengths[a + "-" + b, default: []].append(simd_length(pa - pb)) }
            }
            let t = r(f.timestamp - t0, 5)
            out.append(BodyShotFrame(frameIndex: n, t_file: t, t_real: t, fitted3D: fitted, seen: seen))
        }

        // Bones: rig lengths × uniform scale, so `prior` is true — the length was not measured per bone.
        var boneDict: [String: Any] = [:]
        for (a, b) in bones {
            guard let ls = lengths[a + "-" + b], !ls.isEmpty else { continue }
            let sorted = ls.sorted()
            let median = sorted[sorted.count / 2]
            let mad = ls.map { abs($0 - median) }.sorted()[ls.count / 2]
            boneDict[a + "-" + b] = ["a": a, "b": b, "length": r(median), "mad": r(mad), "frames": ls.count, "prior": true, "symmetricPooled": false] as [String: Any]
        }
        if let l = lengths["leftShoulder-leftElbow"]?.first, let s = lengths["centerShoulder-leftShoulder"]?.first {
            notes.append(String(format: "check of the shoulder choice: |neck_1→left_arm| = %.3f m, |left_arm→left_forearm| = %.3f m", s, l))
        }

        let fps = summary.fps
        let missing: (String) -> [String: Any] = { ["unavailableReason": $0] }
        let scaleNote = summary.scaleMean.map { String(format: "estimatedScaleFactor mean %.4f, min %.4f, max %.4f (%.1f%% spread) over %d detected frames", $0, summary.scaleMin ?? 0, summary.scaleMax ?? 0, summary.scaleSpreadPercent ?? 0, summary.detected) }
            ?? "no detected frame carried a scale factor"

        let timing: BodyShotTiming = try decode([
            "releaseRealTime": -1.0,
            "set": missing("not detected by the ARKit spike"),
            "dip": missing("not detected by the ARKit spike"),
            "followThroughPeak": missing("not detected by the ARKit spike"),
            "quantisationFloor": fps > 0 ? 1 / fps : 0,
            "everyNthFrame": 1,
            "phaseSignal": "none",
            "notes": ["releaseRealTime -1 means unavailable (the schema field is not optional)"],
        ])
        let skeleton: BodyShotSkeleton = try decode([
            "boneLengths": boneDict,
            "unit": "metres",
            "scaleProvenance": "arkit.estimatedScaleFactor",
            "scaleNote": scaleNote,
            "symmetricPrior": false,
            "priorBones": boneDict.keys.sorted(),
            "symmetricBones": [String](),
            "standingHeight": missing("not measured: ARKit reports a scale factor, not a height, and the rig's reference height is undocumented"),
            "depthSigma": missing("ARKit publishes no per-joint uncertainty"),
            "lateralSigma": missing("ARKit publishes no per-joint uncertainty"),
            "reprojectionRMSPixels": missing("not computed by the ARKit spike"),
            "joints": mappings.map(\.map.fitted),
        ])
        let events: BodyShotEvents = try decode([
            "kineticChain": [Any](), "order": [String](), "lagsMs": [Double](),
            "lagFloorMs": fps > 0 ? 1000 / fps : 0,
            "unavailableReason": "kinetic chain not computed by the ARKit spike",
            "missing": [String: String](),
        ])
        let summaryRecord: BodyShotSummary = try decode([
            "jumpHeight": missing("not computed by the ARKit spike"), "dipDepth": missing("not computed by the ARKit spike"),
            "stanceWidth": missing("not computed by the ARKit spike"), "stanceStagger": missing("not computed by the ARKit spike"),
            "hipDrift": missing("not computed by the ARKit spike"), "headStability": missing("not computed by the ARKit spike"),
            "handRateAtRelease": missing("not computed by the ARKit spike"),
        ])
        let hfov = meta.fx > 0 ? 2 * atan(Double(meta.imageWidth) / (2 * Double(meta.fx))) * 180 / .pi : 0
        let source = BodyShotSource(kind: "app", build: build, device: device,
                                    format: BodyShotFormat(w: meta.imageWidth, h: meta.imageHeight, fps: r(fps, 2), hfovDegrees: r(hfov, 2),
                                                           provenance: meta.fx > 0 ? "arkit.intrinsics" : "unavailable"))
        let angles = Dictionary(uniqueKeysWithValues: BodyShot.angleTrackNames.map {
            ($0, BodyShotAngleTrack(samples: [], unavailableReason: "angles not computed by the ARKit spike"))
        })
        let seenFractions = Dictionary(uniqueKeysWithValues: mappings.map { ($0.map.seen, frames.isEmpty ? 0 : r(Double(seenCounts[$0.map.seen] ?? 0) / Double(frames.count))) })
        let conventions = [
            "image": "no 2-D points: ARKit reports the skeleton in 3-D only (project with source.format intrinsics if needed)",
            "camera": "not written: ARKit joints are world-anchored, not camera-relative",
            "body": "origin at hips_joint in the first detected frame; z = ARKit world up (gravity); " + facingNote + "; y = z × x (right-handed); unit: metres (model × estimatedScaleFactor)",
            "time": "t_file = t_real = seconds since the first recorded ARFrame; ARKit runs at the video format's rate (measured fps in source.format)",
            "seen": "isJointTracked per joint per frame; a false entry with no fitted3D key is an untracked or undetected joint",
        ]
        return BodyShot(shotID: nil, source: source, timing: timing, frames: out, skeleton: skeleton, angles: angles,
                        events: events, summary: summaryRecord, seenFractions: seenFractions, symmetryInferred: [],
                        warnings: warnings, notes: notes, shootingSide: nil, conventions: conventions)
    }

    /// The schema's sub-records have no public initialisers outside the package; they are Codable, so they
    /// are built from the JSON they will be stored as — the decoder rejects anything malformed.
    private static func decode<T: Decodable>(_ object: [String: Any]) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
