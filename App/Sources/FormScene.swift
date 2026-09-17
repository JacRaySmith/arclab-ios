import Observation
import SceneKit
import ShotGeometry
import simd

// ================================================================================================
// MARK: - The skeletons in the 3-D form scene
// ================================================================================================
//
// Lifted out of `FormModelView` in 1.2 so the same scene can be built offscreen on the Mac for a
// review render: everything here is Foundation + SceneKit + simd + ShotGeometry, with no SwiftUI and
// no UIKit beyond the `SBColor` typealias `SceneBody.swift` declares.
//
// Three things can be on screen at once, drawn differently on purpose:
//
//   · the **shot** the screen was opened from        — solid, accent
//   · the **ghost**                                   — translucent: the shooter's own best reps at
//     this spot when the rule below finds five of them, otherwise the block's mean form, and the
//     legend says which (`FormGhostBuilder`)
//   · an **earlier session's** mean form              — solid, orange, for progress
//
// and, inside any of them, a joint the tracker never saw is drawn **dashed and thin**, because its
// position is mirrored from the other side of the body, not measured (`ShotForm.inferredBySymmetry`).
// Nothing here is a number: where a form, a phase or a spread is unavailable the screen prints the
// model's own sentence instead of drawing something.

// MARK: - One skeleton in the scene

/// The colours and line weights one skeleton is drawn with.
struct FormLayerStyle: Sendable {
    var colour: SBColor
    var opacity: CGFloat
    var jointRadius: CGFloat
    var boneRadius: CGFloat
    /// Joints the form marks `inferredBySymmetry` are drawn this thin, and in dashes.
    var inferredScale: CGFloat = 0.45

    static let shot = FormLayerStyle(colour: SBColor(red: 0.25, green: 0.56, blue: 1.0, alpha: 1),
                                     opacity: 1.0, jointRadius: 0.022, boneRadius: 0.011)
    /// The ghost: pale and see-through, so the solid shot reads through it at every camera angle.
    static let ghost = FormLayerStyle(colour: SBColor(red: 0.86, green: 0.88, blue: 0.93, alpha: 1),
                                      opacity: 0.38, jointRadius: 0.019, boneRadius: 0.010)
    static let earlier = FormLayerStyle(colour: SBColor(red: 1.0, green: 0.58, blue: 0.16, alpha: 1),
                                        opacity: 0.85, jointRadius: 0.018, boneRadius: 0.009)
}

/// One skeleton's nodes. Geometry is built once — bone lengths are constant over a shot, which is
/// exactly what `BodySkeletonFit` fits — so playback only moves transforms.
@MainActor
final class FormLayer {
    let root = SCNNode()
    private var jointNodes: [SCNNode] = []
    private var ellipsoidNodes: [SCNNode] = []
    private var boneNodes: [[SCNNode]] = []          // one array of capsule segments per bone
    private var boneNominal: [Double] = []           // the joint distance each bone's capsules were built for
    private let boneIndices: [(Int, Int)]
    private let inferred: [Bool]
    private let style: FormLayerStyle
    /// The head, drawn by the same rig the body viewer uses so the two agree about where a skull sits
    /// and which way a face points. Nil when this form carries no nose.
    private var head: SceneHeadRig?
    private let noseIndex: Int?
    private let neckIndex: Int?
    private let hipIndices: (Int, Int)?
    /// The bones the head rig draws itself, so the wireframe does not draw them twice.
    private var bonesDrawnByHead: Set<Int> = []
    /// The ring that marks the joint a callout is open on. Built once, moved and hidden.
    private var highlightNode: SCNNode?
    /// The two oriented hand plates (1.3): wrist · index MCP · little MCP, filled. The three edges are
    /// already in `FormSkeleton.bones`, so this only adds the face — which is what makes a *plate*
    /// read as a plate at any camera angle. A hand the form does not carry has no plate and no edges.
    private var plateNodes: [(node: SCNNode, wrist: Int, index: Int, little: Int)] = []
    private let plateMaterial = SCNMaterial()
    /// Nil while a face is being drawn; otherwise the sentence the legend prints instead.
    var headFaceUnavailableReason: String? { head?.faceUnavailableReason }
    /// Added to every position before it is drawn — how the ghost is aligned on the shot's mid-hip.
    var offset: SIMD3<Double> = .zero

    /// Body frame (x toward the rim, y across the body, z up) → SceneKit (y up, camera down −z).
    /// A cyclic permutation, so it stays right-handed and the default camera looks at the shooter
    /// from the rim: they face you.
    static func scenePoint(_ p: SIMD3<Double>) -> SCNVector3 { SceneBodyMath.scenePoint(p) }

    init(joints: [String], inferred: [Bool], style: FormLayerStyle, boneLengths: [Double],
         showsEllipsoids: Bool, stature: Double? = nil, facingLock: SIMD3<Double>? = nil) {
        self.style = style
        self.inferred = inferred
        self.boneIndices = FormSkeleton.bones.compactMap { bone in
            guard let a = joints.firstIndex(of: bone.a), let b = joints.firstIndex(of: bone.b) else { return nil }
            return (a, b)
        }
        self.noseIndex = joints.firstIndex(of: Body2DPoint.nose)
        self.neckIndex = joints.firstIndex(of: Body2DPoint.neck)
        if let l = joints.firstIndex(of: Body2DPoint.leftHip), let r = joints.firstIndex(of: Body2DPoint.rightHip) {
            self.hipIndices = (l, r)
        } else {
            self.hipIndices = nil
        }
        // The nose→neck bone *is* the neck, and the head rig draws it from the neck up to the skull's
        // base rather than to the nose, so the wireframe must not draw it as well.
        if let n = self.noseIndex, let k = self.neckIndex {
            for (i, pair) in self.boneIndices.enumerated()
            where (pair.0 == n && pair.1 == k) || (pair.0 == k && pair.1 == n) {
                self.bonesDrawnByHead.insert(i)
            }
        }
        let material = SCNMaterial()
        material.diffuse.contents = style.colour
        material.lightingModel = .physicallyBased
        material.roughness.contents = 0.6

        for j in 0..<joints.count {
            let thin = inferred.indices.contains(j) && inferred[j]
            // An appendage corner gets a smaller ball: the whole hand plate is 0.049 statures across
            // and a shoulder-sized sphere at each corner swallows it, which reads as "two blobs"
            // rather than as an oriented plate. The plate itself carries the shape.
            let small = FormSkeleton.appendagePoints.contains(joints[j]) ? 0.45 : 1.0
            let sphere = SCNSphere(radius: style.jointRadius * (thin ? style.inferredScale : 1) * small)
            sphere.segmentCount = 12
            sphere.materials = [material]
            let node = SCNNode(geometry: sphere)
            node.opacity = style.opacity * (thin ? 0.75 : 1)
            node.isHidden = true
            root.addChildNode(node)
            jointNodes.append(node)

            let ell = SCNSphere(radius: 1)
            ell.segmentCount = 10
            let em = SCNMaterial()
            em.diffuse.contents = style.colour.withAlphaComponent(0.18)
            em.isDoubleSided = true
            em.lightingModel = .constant
            ell.materials = [em]
            let en = SCNNode(geometry: ell)
            en.isHidden = true
            root.addChildNode(en)
            ellipsoidNodes.append(en)
        }

        for (i, pair) in boneIndices.enumerated() {
            let dashed = (inferred.indices.contains(pair.0) && inferred[pair.0])
                || (inferred.indices.contains(pair.1) && inferred[pair.1])
            let length = boneLengths.indices.contains(i) ? boneLengths[i] : 0.3
            var radius = style.boneRadius * (dashed ? style.inferredScale : 1)
            if FormSkeleton.appendagePoints.contains(joints[pair.0]) || FormSkeleton.appendagePoints.contains(joints[pair.1]) {
                radius *= 0.45          // the plate's own edges: an outline, not a bone
            }
            // A dashed bone is real dashes: seven short capsules with six gaps, so it reads as
            // "inferred" at any angle, which a translucent solid bone does not.
            let count = dashed ? 7 : 1
            let segmentLength = dashed ? length / Double(2 * count - 1) : length
            var segs: [SCNNode] = []
            for _ in 0..<count {
                let capsule = SCNCapsule(capRadius: radius, height: max(0.001, CGFloat(segmentLength)))
                capsule.radialSegmentCount = 8
                capsule.materials = [material]
                let node = SCNNode(geometry: capsule)
                node.opacity = style.opacity * (dashed ? 0.7 : 1)
                node.isHidden = true
                root.addChildNode(node)
                segs.append(node)
            }
            boneNodes.append(segs)
            boneNominal.append(max(length, 1e-4))
        }
        // ---- the head ----
        // Built only when this form carries a nose: the head hangs off one measured joint and there
        // is nothing honest to draw without it. The skull is translucent here — this viewer is a
        // wireframe and a solid head would hide the skeleton — while the face marks stay solid, so
        // which way the shooter looks is readable at any camera angle.
        if noseIndex != nil, let S = stature, S > 1e-6 {
            let feature = SCNMaterial()
            feature.diffuse.contents = style.colour
            feature.lightingModel = .constant
            let skin = SCNMaterial()
            skin.diffuse.contents = style.colour.withAlphaComponent(0.30)
            skin.lightingModel = .physicallyBased
            skin.roughness.contents = 0.7
            skin.isDoubleSided = true
            let rig = SceneHeadRig(stature: S, facingLock: facingLock, skin: skin, feature: feature,
                                   skullOpacity: style.opacity * 0.5, neckRadius: 0.012, markScale: 0.85)
            head = rig
            root.addChildNode(rig.root)
        }
        // ---- the hand plates ----
        plateMaterial.diffuse.contents = style.colour.withAlphaComponent(0.45 * style.opacity)
        plateMaterial.lightingModel = .constant
        plateMaterial.isDoubleSided = true
        for side in ["left", "right"] {
            guard let w = joints.firstIndex(of: side + "Wrist"),
                  let i = joints.firstIndex(of: side + "IndexMCP"),
                  let l = joints.firstIndex(of: side + "LittleMCP") else { continue }
            let node = SCNNode()
            node.isHidden = true
            root.addChildNode(node)
            plateNodes.append((node, w, i, l))
        }
        setEllipsoidsVisible(showsEllipsoids)
    }

    private var ellipsoidsOn = false
    func setEllipsoidsVisible(_ on: Bool) {
        ellipsoidsOn = on
        if !on { for n in ellipsoidNodes { n.isHidden = true } }
    }

    func setVisible(_ on: Bool) { root.isHidden = !on }

    /// Move the skeleton to one instant. `spreads` is the 1σ per axis, or nil where the block has no
    /// spread — and then no ellipsoid is drawn rather than a zero-sized one.
    func update(positions: [SIMD3<Double>?], spreads: [SIMD3<Double>?]?) {
        let shift = offset
        func moved(_ p: SIMD3<Double>?) -> SIMD3<Double>? { p.map { $0 + shift } }
        // The head first, so the nose sphere below can be left to it.
        if let rig = head, let n = noseIndex, n < positions.count, let nose = moved(positions[n]) {
            let neck = neckIndex.flatMap { $0 < positions.count ? moved(positions[$0]) : nil }
            var midHip: SIMD3<Double>? = nil
            if let (l, r) = hipIndices, l < positions.count, r < positions.count,
               let a = moved(positions[l]), let b = moved(positions[r]) { midHip = (a + b) / 2 }
            rig.update(nose: nose, neck: neck, midHip: midHip, opacity: style.opacity)
        } else {
            head?.hide()
        }
        for (j, node) in jointNodes.enumerated() {
            // The nose is drawn by the head rig as the face's own mark, not as a skeleton joint.
            if head != nil && j == noseIndex { node.isHidden = true; ellipsoidNodes[j].isHidden = true; continue }
            guard j < positions.count, let p = moved(positions[j]) else { node.isHidden = true; ellipsoidNodes[j].isHidden = true; continue }
            node.isHidden = false
            node.position = Self.scenePoint(p)
            let e = ellipsoidNodes[j]
            if ellipsoidsOn, let s = spreads?[j], simd_length(s) > 1e-9 {
                e.isHidden = false
                e.position = node.position
                let v = Self.scenePoint(s)
                e.scale = SCNVector3(max(v.x, 0.001), max(v.y, 0.001), max(v.z, 0.001))
            } else {
                e.isHidden = true
            }
        }
        for (i, pair) in boneIndices.enumerated() {
            let segs = boneNodes[i]
            if bonesDrawnByHead.contains(i) { for n in segs { n.isHidden = true }; continue }
            guard pair.0 < positions.count, pair.1 < positions.count,
                  let a = moved(positions[pair.0]), let b = moved(positions[pair.1]) else {
                for n in segs { n.isHidden = true }
                continue
            }
            let pa = Self.scenePoint(a), pb = Self.scenePoint(b)
            let d = SIMD3<Float>(Float(pb.x - pa.x), Float(pb.y - pa.y), Float(pb.z - pa.z))
            let len = simd_length(d)
            guard len > 1e-6 else { for n in segs { n.isHidden = true }; continue }
            let dir = d / len
            let q = SceneBodyMath.orientation(along: dir)
            let count = segs.count
            // The capsules were built for the form's median joint distance; scale them along their
            // own axis so the bone runs joint to joint on every sample, never centred between two
            // joints it does not reach.
            let stretch = len / Float(boneNominal[i])
            for (k, node) in segs.enumerated() {
                node.isHidden = false
                // Solid: one capsule at the midpoint. Dashed: capsules on the odd sub-intervals.
                let f = count == 1 ? 0.5 : (Float(2 * k) + 0.5) / Float(2 * count - 1)
                let centre = SIMD3<Float>(Float(pa.x), Float(pa.y), Float(pa.z)) + dir * (len * f)
                node.simdPosition = centre
                node.simdOrientation = q
                node.simdScale = SIMD3<Float>(1, stretch, 1)
            }
        }
        for plate in plateNodes {
            guard let w = moved(plate.wrist < positions.count ? positions[plate.wrist] : nil),
                  let i = moved(plate.index < positions.count ? positions[plate.index] : nil),
                  let l = moved(plate.little < positions.count ? positions[plate.little] : nil) else {
                plate.node.isHidden = true; continue
            }
            plate.node.geometry = SceneBodyMath.triangle(w, i, l, material: plateMaterial)
            plate.node.isHidden = false
        }
        if let h = highlightNode, let j = highlightedJoint, jointNodes.indices.contains(j), !jointNodes[j].isHidden {
            h.isHidden = false
            h.simdPosition = jointNodes[j].simdPosition
        } else {
            highlightNode?.isHidden = true
        }
    }

    // MARK: The callout's marker

    private(set) var highlightedJoint: Int?

    /// Ring the joint a callout is open on, or clear it. The ring carries no number: it only says
    /// which joint the card beside the scene is talking about.
    func highlight(_ index: Int?) {
        highlightedJoint = index
        if highlightNode == nil {
            let torus = SCNTorus(ringRadius: CGFloat(style.jointRadius * 2.4), pipeRadius: CGFloat(style.jointRadius * 0.45))
            let m = SCNMaterial()
            m.diffuse.contents = SBColor(red: 1.0, green: 0.84, blue: 0.20, alpha: 1)
            m.lightingModel = .constant
            torus.materials = [m]
            let n = SCNNode(geometry: torus)
            n.constraints = [SCNBillboardConstraint()]
            n.isHidden = true
            root.addChildNode(n)
            highlightNode = n
        }
        if index == nil { highlightNode?.isHidden = true }
        else if let j = index, jointNodes.indices.contains(j), !jointNodes[j].isHidden {
            highlightNode?.isHidden = false
            highlightNode?.simdPosition = jointNodes[j].simdPosition
        }
    }

    /// Where the drawn joints are in world space right now — what a tap is matched against.
    /// Hidden joints are left out: a joint that is not drawn cannot be tapped.
    func drawnJointsInWorld(_ indices: [Int]) -> [(index: Int, world: SIMD3<Float>)] {
        indices.compactMap { j in
            guard jointNodes.indices.contains(j), !jointNodes[j].isHidden else { return nil }
            return (j, jointNodes[j].simdWorldPosition)
        }
    }
}

// MARK: - The scene

@MainActor
@Observable
final class FormSceneModel {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    private(set) var shotLayer: FormLayer?
    private(set) var ghostLayer: FormLayer?
    private(set) var earlierLayer: FormLayer?
    let content = SCNNode()
    /// The shooter's height in the form's own unit, for the camera distances. 1 until a form is in.
    var stature: Double = 1
    /// Scene-space height of the floor and of the rulebook rim, once a form has said where they are.
    var floorSceneHeight: Float = 0
    var rimSceneHeight: Float?

    /// A fixed dark ground, not the system background: the skeletons are pale, the scrims over them
    /// are dark, and a screen that flips to white in light mode would make both unreadable.
    static let background = SBColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1)

    init() {
        scene.background.contents = Self.background
        scene.rootNode.addChildNode(content)
        let camera = SCNCamera()
        camera.fieldOfView = 40
        camera.zNear = 0.01
        camera.zFar = 100
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0.3, 0.15, 3.4)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 700
        key.position = SCNVector3(2, 4, 3)
        key.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(key)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 450
        scene.rootNode.addChildNode(ambient)
    }

    /// The offset that puts the middle of the body at the camera's target. The body frame's origin is
    /// the mid-hip **at the set point**, so without this the skeleton hangs off the top of the frame
    /// and sits to one side of it by however far the shooter travelled.
    ///
    /// It is a constant for the whole clip — the mean over the samples — never a per-frame follow:
    /// a camera that chased the body would hide the travel, which is one of the things the screen is
    /// there to show.
    func centre(on heightRange: ClosedRange<Double>, midHip: SIMD3<Double>? = nil) {
        let mid = (heightRange.lowerBound + heightRange.upperBound) / 2
        content.simdPosition = SIMD3<Float>(Float(-(midHip?.y ?? 0)), Float(-mid), Float(-(midHip?.x ?? 0)))
        floorSceneHeight = Float(heightRange.lowerBound - mid)
    }

    /// The point every preset looks at: the origin, because `centre(on:)` already moved the body to it.
    var target: SIMD3<Float> { .zero }

    func apply(_ preset: FormCameraPreset) {
        guard let pose = preset.pose(stature: stature, target: target, floorSceneHeight: floorSceneHeight,
                                     rimSceneHeight: rimSceneHeight) else { return }
        cameraNode.simdPosition = pose.position
        cameraNode.simdLook(at: pose.target)
    }

    func setShot(_ layer: FormLayer?) { replace(&shotLayer, with: layer) }
    func setGhost(_ layer: FormLayer?) { replace(&ghostLayer, with: layer) }
    func setEarlier(_ layer: FormLayer?) { replace(&earlierLayer, with: layer) }

    private func replace(_ slot: inout FormLayer?, with layer: FormLayer?) {
        slot?.root.removeFromParentNode()
        slot = layer
        if let layer { content.addChildNode(layer.root) }
    }
}

// MARK: - Sampling the forms

/// Reading one instant out of a shot or a block, and the few whole-clip quantities the drawing needs
/// (bone lengths, stature, the locked facing). Pure arithmetic over `ShotForm` / `FormModel`, kept
/// here rather than on the screen so the offscreen renderer can use exactly the same code.
enum FormSampling {


    static func positions(of f: ShotForm, at tau: Double) -> [SIMD3<Double>?] {
        guard let s = nearest(f.samples, tau, { $0.t }) else { return Array(repeating: nil, count: f.joints.count) }
        return s.positions
    }

    static func positions(of m: FormModel, at tau: Double) -> ([SIMD3<Double>?], [SIMD3<Double>?]) {
        guard let s = nearest(m.samples, tau, { $0.t }) else {
            return (Array(repeating: nil, count: m.joints.count), Array(repeating: nil, count: m.joints.count))
        }
        let idx = 0..<m.joints.count
        return (idx.map { s.position($0) }, idx.map { s.spread($0) })
    }

    static func nearest<T>(_ xs: [T], _ tau: Double, _ key: (T) -> Double) -> T? {
        xs.min { abs(key($0) - tau) < abs(key($1) - tau) }
    }

    /// The median length of each drawn bone over the whole shot. Constant by construction — the fit
    /// holds bone lengths fixed — so the capsules are built once and only moved during playback.
    static func lengths(of f: ShotForm) -> [Double] {
        lengths(joints: f.joints, samples: f.samples.map(\.positions))
    }
    static func lengths(of m: FormModel) -> [Double] {
        lengths(joints: m.joints, samples: m.samples.map { s in (0..<m.joints.count).map { s.position($0) } })
    }
    static func lengths(joints: [String], samples: [[SIMD3<Double>?]]) -> [Double] {
        FormSkeleton.bones.map { bone in
            guard let ia = joints.firstIndex(of: bone.a), let ib = joints.firstIndex(of: bone.b) else { return 0.3 }
            let ls = samples.compactMap { s -> Double? in
                guard ia < s.count, ib < s.count, let a = s[ia], let b = s[ib] else { return nil }
                return simd_length(a - b)
            }.sorted()
            return ls.isEmpty ? 0.3 : ls[ls.count / 2]
        }
    }

    /// The shooter's stature in the form's own length unit: the 90th-percentile nose-to-ankle span
    /// over the samples ÷ 0.891, which is the convention the fit and the export already use, so a
    /// head proportion means the same fraction of the same person in every view.
    static func stature(joints: [String], samples: [[SIMD3<Double>?]]) -> Double? {
        guard let n = joints.firstIndex(of: Body2DPoint.nose) else { return nil }
        let ankles = [Body2DPoint.leftAnkle, Body2DPoint.rightAnkle].compactMap { joints.firstIndex(of: $0) }
        guard !ankles.isEmpty else { return nil }
        var spans: [Double] = []
        for s in samples {
            guard n < s.count, let nose = s[n] else { continue }
            let d = ankles.compactMap { $0 < s.count ? s[$0] : nil }.map { simd_length($0 - nose) }
            if let m = d.max() { spans.append(m) }
        }
        guard !spans.isEmpty else { return nil }
        spans.sort()
        let p90 = spans[min(spans.count - 1, Int((0.9 * Double(spans.count - 1)).rounded()))]
        return p90 > 1e-6 ? p90 / 0.891 : nil
    }

    /// The form's own facing direction, locked over the whole clip so the drawn head cannot flip.
    /// Main-actor because the head rig it asks is: the rig is a scene object, and this is the one
    /// piece of sampling that belongs to it.
    @MainActor
    static func facingLock(joints: [String], samples: [[SIMD3<Double>?]], stature: Double) -> SIMD3<Double>? {
        guard let n = joints.firstIndex(of: Body2DPoint.nose) else { return nil }
        let k = joints.firstIndex(of: Body2DPoint.neck)
        let lh = joints.firstIndex(of: Body2DPoint.leftHip), rh = joints.firstIndex(of: Body2DPoint.rightHip)
        var triples: [(nose: SIMD3<Double>, neck: SIMD3<Double>?, midHip: SIMD3<Double>?)] = []
        for s in samples {
            guard n < s.count, let nose = s[n] else { continue }
            let neck = k.flatMap { $0 < s.count ? s[$0] : nil }
            var mid: SIMD3<Double>? = nil
            if let l = lh, let r = rh, l < s.count, r < s.count, let a = s[l], let b = s[r] { mid = (a + b) / 2 }
            triples.append((nose, neck, mid))
        }
        return SceneHeadRig.facingLock(samples: triples, stature: stature)
    }

    static func heightRange(of f: ShotForm) -> ClosedRange<Double>? {
        range(f.samples.map(\.positions))
    }
    static func heightRange(of m: FormModel) -> ClosedRange<Double>? {
        range(m.samples.map { s in (0..<m.joints.count).map { s.position($0) } })
    }
    /// The mean mid-hip over the whole clip, in the form's own frame — where the body sits on average,
    /// which is where the camera should be pointed.
    static func meanMidHip(joints: [String], samples: [[SIMD3<Double>?]]) -> SIMD3<Double>? {
        guard let l = joints.firstIndex(of: Body2DPoint.leftHip),
              let r = joints.firstIndex(of: Body2DPoint.rightHip) else { return nil }
        var sum = SIMD3<Double>.zero
        var n = 0
        for s in samples {
            guard l < s.count, r < s.count, let a = s[l], let b = s[r] else { continue }
            sum += (a + b) / 2
            n += 1
        }
        return n > 0 ? sum / Double(n) : nil
    }

    static func range(_ samples: [[SIMD3<Double>?]]) -> ClosedRange<Double>? {
        let zs = samples.flatMap { $0.compactMap { $0?.z } }
        guard let lo = zs.min(), let hi = zs.max(), hi > lo else { return nil }
        return lo...hi
    }
}
