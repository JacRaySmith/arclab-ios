import Foundation
import SceneKit
import ShotGeometry
import simd

#if canImport(UIKit)
import UIKit
typealias SBColor = UIColor
#else
import AppKit
typealias SBColor = NSColor
#endif

// ================================================================================================
// MARK: - A proportioned body in a SceneKit scene
// ================================================================================================
//
// `FormModelView` draws a *skeleton* — spheres and sticks on the phase-normalised clock. This file
// draws a **body**: the same fitted joints, wearing the volume its own bone lengths imply, played
// back frame by frame off a `BodyShot` file (docs/BIOMETRIC-SCHEMA.md §3).
//
// The honesty line is the same one the rest of the app holds, and it matters more here because a
// rendering is persuasive:
//
//   · Every **position** is the file's `fitted3D`. A joint the file does not carry is not drawn.
//   · A joint in `symmetryInferred` is drawn translucent; one the tracker did not see on this frame
//     is drawn half-lit. Neither is ever drawn solid.
//   · Every **thickness** — torso width and depth, limb radii, head size, the mitt — is a *drawn
//     proportion*, not a measurement. It is derived from the shooter's own segment lengths where
//     those are observable and from an anthropometric floor where they are not (a near-side view
//     cannot see the shoulder line's depth, and the fit says so). Nothing in this file may be read
//     off the screen as a number; the readouts print the model's own values and reasons instead.
//   · Hand landmarks are **2-D**. Fingers are therefore drawn flat, in the image plane, anchored at
//     the measured 3-D wrist. That is exactly what was measured and the legend says so. With no
//     landmarks the hand is a mitt.
//
// Everything here is Foundation + SceneKit + simd + ShotGeometry, with no SwiftUI and no UIKit
// beyond the colour typealias, so the same scene can be rendered offscreen on the Mac for review.

// MARK: - Shared geometry helpers (also used by FormModelView)

enum SceneBodyMath {

    /// Body frame (x toward the rim, y across the body, z up) → SceneKit (y up, camera down −z).
    /// A cyclic permutation, so it stays right-handed and the default camera looks at the shooter
    /// from the rim: they face you.
    /// `SCNVector3`'s components are `Float` on iOS and `CGFloat` on macOS, so it is always built
    /// from the simd form — this file is compiled on both.
    static func scenePoint(_ p: SIMD3<Double>) -> SCNVector3 {
        SCNVector3(simdPoint(p))
    }

    static func simdPoint(_ p: SIMD3<Double>) -> SIMD3<Float> {
        SIMD3<Float>(Float(p.y), Float(p.z), Float(p.x))
    }

    /// A flat, double-sided triangle through three points in the **body frame**. Rebuilt each frame
    /// rather than transformed: three vertices are nothing to allocate, and an affine transform of a
    /// fixed triangle would shear the plate whenever the fit's own two knuckles disagreed with the
    /// size prior by a per cent. The plate is what was fitted, drawn where it was fitted.
    static func triangle(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>,
                         material: SCNMaterial) -> SCNGeometry {
        let v = [simdPoint(a), simdPoint(b), simdPoint(c)].map { SCNVector3($0) }
        let source = SCNGeometrySource(vertices: v)
        let element = SCNGeometryElement(indices: [Int32(0), 1, 2], primitiveType: .triangles)
        let g = SCNGeometry(sources: [source], elements: [element])
        g.materials = [material]
        return g
    }

    /// The rotation that takes a geometry built along +y onto `dir` (already normalised).
    /// `simd_quatf(from:to:)` is undefined for exactly opposite vectors, so that case is named.
    static func orientation(along dir: SIMD3<Float>) -> simd_quatf {
        let up = SIMD3<Float>(0, 1, 0)
        let d = simd_dot(up, dir)
        if d < -0.999999 { return simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0)) }
        if d > 0.999999 { return simd_quatf(angle: 0, axis: up) }
        return simd_quatf(from: up, to: dir)
    }

    /// Put a node whose geometry runs along +y and is centred on its origin onto the segment a→b.
    /// Returns the segment's length, or 0 when it is degenerate (the caller then hides the node).
    /// With `stretchingUnitHeight` the geometry is assumed one unit tall and is scaled to fit.
    @discardableResult
    static func align(_ node: SCNNode, from a: SIMD3<Double>, to b: SIMD3<Double>,
                      stretchingUnitHeight: Bool = false) -> Float {
        let pa = simdPoint(a), pb = simdPoint(b)
        let delta = pb - pa
        let len = simd_length(delta)
        guard len > 1e-6 else { return 0 }
        let dir = delta / len
        node.simdPosition = pa + dir * (len / 2)
        node.simdOrientation = orientation(along: dir)
        if stretchingUnitHeight { node.simdScale = SIMD3<Float>(1, len, 1) }
        return len
    }
}

// MARK: - Colours

struct SceneBodyPalette: Sendable {
    var neutral: SBColor
    var shooting: SBColor
    var guideArm: SBColor
    var grid: SBColor
    var rim: SBColor
    /// The face marks — nose, eyes, chin. Dark enough to read against the skull from any angle.
    var feature: SBColor = SBColor(red: 0.16, green: 0.18, blue: 0.22, alpha: 1)

    /// Mid-tones on purpose: each one keeps its contrast against a light and a dark backdrop, so the
    /// scene does not need a second palette for dark mode.
    static let standard = SceneBodyPalette(
        neutral: SBColor(red: 0.58, green: 0.61, blue: 0.68, alpha: 1),
        shooting: SBColor(red: 0.95, green: 0.52, blue: 0.16, alpha: 1),
        guideArm: SBColor(red: 0.22, green: 0.66, blue: 0.74, alpha: 1),
        grid: SBColor(red: 0.50, green: 0.53, blue: 0.60, alpha: 1),
        rim: SBColor(red: 0.28, green: 0.72, blue: 0.44, alpha: 1))
}

// MARK: - Names

/// The `fitted3D` keys this file draws, and how they map onto the 2-D point names the per-frame
/// `seen` flags use (`Body3DJoint.centerHead` is the nose, `centerShoulder` the neck).
enum SceneBodyJoints {
    static let root = "root", spine = "spine", centerShoulder = "centerShoulder", centerHead = "centerHead"

    static func side(_ s: String, _ j: String) -> String { s + j.prefix(1).uppercased() + j.dropFirst() }

    static let drawn: [String] = [
        root, spine, centerShoulder, centerHead,
        "leftShoulder", "rightShoulder", "leftElbow", "rightElbow", "leftWrist", "rightWrist",
        "leftHip", "rightHip", "leftKnee", "rightKnee", "leftAnkle", "rightAnkle",
    ]

    /// The key the per-frame `seen` dictionary uses for a fitted joint.
    static func seenKey(_ fitted: String) -> String {
        switch fitted {
        case centerHead: return "nose"
        case centerShoulder: return "neck"
        default: return fitted
        }
    }

    /// The five 2-D finger chains, wrist first. Vision's hand landmark names.
    static let fingerChains: [[String]] = [
        ["wrist", "thumbCMC", "thumbMP", "thumbIP", "thumbTip"],
        ["wrist", "indexMCP", "indexPIP", "indexDIP", "indexTip"],
        ["wrist", "middleMCP", "middlePIP", "middleDIP", "middleTip"],
        ["wrist", "ringMCP", "ringPIP", "ringDIP", "ringTip"],
        ["wrist", "littleMCP", "littlePIP", "littleDIP", "littleTip"],
    ]
    static let palmLinks: [(String, String)] = [
        ("thumbCMC", "indexMCP"), ("indexMCP", "middleMCP"),
        ("middleMCP", "ringMCP"), ("ringMCP", "littleMCP"),
    ]
}

// MARK: - Proportions

/// The lengths the body is built from and the scale its thicknesses are drawn at.
///
/// Every length here is measured off the file (the median over its own frames, which the skeleton fit
/// holds constant by construction). Every *thickness* is a drawn proportion — a fraction of the
/// shooter's stature, floored where the view cannot see the real one. `notes` says which.
struct SceneBodyProportions: Sendable {
    /// Rendering scale: the shooter's stature in the file's own unit (metres, or 1 for a unit-height
    /// file). Never quoted as a measurement — `BodyShot.skeleton.standingHeight` is the number.
    var stature: Double
    var unit: String
    /// Median segment lengths, body-frame units, by drawn-segment name.
    var lengths: [String: Double]
    /// The lowest the ankles ever go, minus the ankle-to-sole offset: where the floor grid sits.
    var floorHeight: Double
    /// The vertical middle of the body over the whole shot, for the camera's target.
    var midHeight: Double
    /// Sign that takes a rightward step in image pixels onto the body frame's x axis, measured from
    /// the shoulders' own 2-D and 3-D positions. Nil when no frame carried both.
    var imageURunsWithBodyX: Double?
    var notes: [String]

    func length(_ name: String) -> Double? { lengths[name] }
}

extension SceneBodyProportions {

    static func measure(_ shot: BodyShot) -> SceneBodyProportions {
        let frames = shot.frames
        func p(_ f: BodyShotFrame, _ j: String) -> SIMD3<Double>? {
            f.fitted3D[j].map { SIMD3($0.x, $0.y, $0.z) }
        }
        func median(_ xs: [Double]) -> Double? {
            guard !xs.isEmpty else { return nil }
            let s = xs.sorted(); return s[s.count / 2]
        }
        func percentile(_ xs: [Double], _ q: Double) -> Double? {
            guard !xs.isEmpty else { return nil }
            let s = xs.sorted()
            return s[min(s.count - 1, max(0, Int((Double(s.count - 1) * q).rounded())))]
        }

        // ---- segment lengths: the median over the file's own frames ----
        let segments: [(String, String, String)] = [
            ("pelvis", SceneBodyJoints.root, SceneBodyJoints.spine),
            ("chest", SceneBodyJoints.spine, SceneBodyJoints.centerShoulder),
            ("neck", SceneBodyJoints.centerShoulder, SceneBodyJoints.centerHead),
            ("biacromial", "leftShoulder", "rightShoulder"),
            ("biiliac", "leftHip", "rightHip"),
            ("upperArmLeft", "leftShoulder", "leftElbow"),
            ("upperArmRight", "rightShoulder", "rightElbow"),
            ("forearmLeft", "leftElbow", "leftWrist"),
            ("forearmRight", "rightElbow", "rightWrist"),
            ("thighLeft", "leftHip", "leftKnee"),
            ("thighRight", "rightHip", "rightKnee"),
            ("shinLeft", "leftKnee", "leftAnkle"),
            ("shinRight", "rightKnee", "rightAnkle"),
        ]
        var lengths: [String: Double] = [:]
        for (name, a, b) in segments {
            let ls = frames.compactMap { f -> Double? in
                guard let pa = p(f, a), let pb = p(f, b) else { return nil }
                return simd_length(pa - pb)
            }
            if let m = median(ls), m > 1e-6 { lengths[name] = m }
        }

        // ---- stature: the stated standing height when there is one, else the file's own span ----
        var notes: [String] = []
        var stature: Double
        let unit = shot.skeleton.unit
        if let stated = shot.skeleton.standingHeight.value, stated > 0, unit == "metres" {
            stature = stated
            notes.append("the body is drawn at the stated standing height (\(String(format: "%.2f", stated)) m).")
        } else {
            // ankle-to-nose span ÷ 0.891, the same convention the export used for its unit height.
            let spans = frames.compactMap { f -> Double? in
                guard let head = p(f, SceneBodyJoints.centerHead) else { return nil }
                let ankles = [p(f, "leftAnkle")?.z, p(f, "rightAnkle")?.z].compactMap { $0 }
                guard let lowest = ankles.min() else { return nil }
                return head.z - lowest
            }
            stature = (percentile(spans, 0.9) ?? 0.891) / 0.891
            notes.append("no standing height was stated, so the body is drawn at the file's own unit scale (\(unit)); the numbers below are the file's, the thicknesses are proportions.")
        }
        if !(stature.isFinite && stature > 1e-6) { stature = 1 }

        // ---- floor and the camera's vertical target ----
        let ankleZ = frames.flatMap { f in [p(f, "leftAnkle")?.z, p(f, "rightAnkle")?.z].compactMap { $0 } }
        let allZ = frames.flatMap { f in SceneBodyJoints.drawn.compactMap { p(f, $0)?.z } }
        let floor = (ankleZ.min() ?? -0.5 * stature) - 0.045 * stature
        let mid = ((allZ.min() ?? floor) + (allZ.max() ?? floor + stature)) / 2

        // ---- which way image columns run in the body frame (for the flat hands) ----
        var votes = 0.0, seen = 0
        for f in frames {
            guard let uL = f.points2D["leftShoulder"], let uR = f.points2D["rightShoulder"],
                  let xL = p(f, "leftShoulder"), let xR = p(f, "rightShoulder") else { continue }
            let du = uL.u - uR.u, dx = xL.x - xR.x
            guard abs(du) > 2, abs(dx) > 1e-4 else { continue }
            votes += (du * dx > 0) ? 1 : -1
            seen += 1
        }
        let uSign: Double? = seen >= 5 ? (votes >= 0 ? 1 : -1) : nil
        if uSign == nil {
            notes.append("the direction image columns run in the body frame could not be measured, so the hands are drawn as mitts rather than in a flipped pose.")
        }

        if (lengths["biacromial"] ?? 0) < 0.19 * stature {
            notes.append("the fitted shoulder line is narrower than an adult's: on this view its depth is not observable, so the torso's drawn width falls back to an anthropometric proportion.")
        }

        return SceneBodyProportions(stature: stature, unit: unit, lengths: lengths,
                                    floorHeight: floor, midHeight: mid,
                                    imageURunsWithBodyX: uSign, notes: notes)
    }
}

// MARK: - One hand

/// Twenty-four unit-height capsules for the fingers and the palm, plus a mitt for the frames that
/// have no landmarks. Geometry is built once; playback only moves and stretches transforms.
@MainActor
private final class SceneHandRig {
    let root = SCNNode()
    private var boneNodes: [SCNNode] = []
    private var bonePairs: [(String, String)] = []
    private let mitt = SCNNode()
    /// The oriented hand plate (1.3): the fitted wrist · index MCP · little MCP triangle. Drawn only
    /// when all three points were confident on the frame, so the palm actually has a normal.
    private let plate = SCNNode()
    private let plateMaterial = SCNMaterial()
    private let plateColour: SBColor

    init(stature: Double, material: SCNMaterial) {
        self.plateColour = (material.diffuse.contents as? SBColor) ?? SBColor.white
        for chain in SceneBodyJoints.fingerChains {
            for k in 0..<(chain.count - 1) {
                bonePairs.append((chain[k], chain[k + 1]))
                boneNodes.append(Self.capsule(radius: (k < 2 ? 0.0090 : 0.0065) * stature, material: material))
            }
        }
        for link in SceneBodyJoints.palmLinks {
            bonePairs.append(link)
            boneNodes.append(Self.capsule(radius: 0.0085 * stature, material: material))
        }
        for n in boneNodes { n.isHidden = true; root.addChildNode(n) }

        let m = SCNCapsule(capRadius: CGFloat(0.030 * stature), height: 1)
        m.radialSegmentCount = 10
        m.materials = [material]
        mitt.geometry = m
        mitt.isHidden = true
        root.addChildNode(mitt)

        plateMaterial.diffuse.contents = plateColour.withAlphaComponent(0.55)
        plateMaterial.lightingModel = .constant
        plateMaterial.isDoubleSided = true
        plate.isHidden = true
        root.addChildNode(plate)
    }

    private static func capsule(radius: Double, material: SCNMaterial) -> SCNNode {
        let c = SCNCapsule(capRadius: CGFloat(max(radius, 0.0005)), height: 1)
        c.radialSegmentCount = 6
        c.heightSegmentCount = 1
        c.materials = [material]
        return SCNNode(geometry: c)
    }

    func hide() {
        for n in boneNodes { n.isHidden = true }
        mitt.isHidden = true
        plate.isHidden = true
    }

    /// The fitted plate. `certain` is false when a corner was carried across a sampled frame or was
    /// clamped onto the size prior's sphere; the plate is then drawn fainter, and the legend says so.
    func showPlate(_ t: BodyShotHandTriangle, certain: Bool) {
        guard let i = t.indexMCP, let l = t.littleMCP else { plate.isHidden = true; return }
        for n in boneNodes { n.isHidden = true }
        mitt.isHidden = true
        plateMaterial.diffuse.contents = plateColour.withAlphaComponent(certain ? 0.55 : 0.22)
        plate.geometry = SceneBodyMath.triangle(SIMD3(t.wrist.x, t.wrist.y, t.wrist.z),
                                                SIMD3(i.x, i.y, i.z), SIMD3(l.x, l.y, l.z),
                                                material: plateMaterial)
        plate.isHidden = false
    }

    func hidePlate() { plate.isHidden = true }

    /// Draw the measured 2-D landmarks flat, in the image plane, anchored at the 3-D wrist.
    /// `uSign` is which way image columns run along the body frame's x.
    func showFingers(_ landmarks: [String: BodyShotPoint2D], wrist3D: SIMD3<Double>, scale: Double, uSign: Double) {
        guard let w = landmarks["wrist"] else { hide(); return }
        func place(_ name: String) -> SIMD3<Double>? {
            guard let l = landmarks[name] else { return nil }
            return wrist3D
                + SIMD3(uSign * (l.u - w.u) * scale, 0, 0)
                - SIMD3(0, 0, (l.v - w.v) * scale)      // image v runs down, body z runs up
        }
        mitt.isHidden = true
        plate.isHidden = true
        for (i, pair) in bonePairs.enumerated() {
            let node = boneNodes[i]
            guard let a = place(pair.0), let b = place(pair.1),
                  SceneBodyMath.align(node, from: a, to: b, stretchingUnitHeight: true) > 0 else {
                node.isHidden = true; continue
            }
            node.isHidden = false
        }
    }

    /// No landmarks on this frame: a mitt, pointed the way the forearm points.
    func showMitt(wrist3D: SIMD3<Double>, elbow3D: SIMD3<Double>?, stature: Double) {
        for n in boneNodes { n.isHidden = true }
        plate.isHidden = true
        var dir = SIMD3<Double>(0, 0, 1)
        if let e = elbow3D {
            let d = wrist3D - e
            if simd_length(d) > 1e-6 { dir = simd_normalize(d) }
        }
        mitt.isHidden = false
        SceneBodyMath.align(mitt, from: wrist3D, to: wrist3D + dir * (0.095 * stature),
                            stretchingUnitHeight: true)
    }
}

// MARK: - The head

/// A head that reads as a head: a skull ellipsoid seated on the neck, with the measured nose on its
/// front surface and — **only when the view says which way the shooter faces** — two eyes and a chin
/// line marking the face side.
///
/// What is measured and what is drawn:
///
///   · the **nose** and the **neck** are fitted joints, and the skull is placed off them;
///   · the **facing direction** is the horizontal part of neck → nose, which is the same cue
///     `BodyKinematics.head` takes from the image, read off the fitted skeleton so the drawn face can
///     never disagree with the drawn body. It is refused when the offset is inside the keypoint
///     jitter, and then the skull is bare — no eyes, no chin — and the legend says why;
///   · every **proportion** of the skull (`HeadProportions`) is adult anthropometry scaled by the
///     shooter's own stature. A single camera does not measure a skull. Nothing on it is a number.
@MainActor
final class SceneHeadRig {
    let root = SCNNode()
    private let skull = SCNNode()
    private let nose = SCNNode()
    private let eyeLeft = SCNNode()
    private let eyeRight = SCNNode()
    private let chin = SCNNode()
    private let neck = SCNNode()
    private let stature: Double
    private let facingLock: SIMD3<Double>?
    /// Nil while a face is being drawn; otherwise the sentence the legend prints instead.
    private(set) var faceUnavailableReason: String?

    /// `skullOpacity` below 1 is for the wireframe viewer, where a solid skull would hide the
    /// skeleton it sits on; the face marks stay solid so the facing still reads.
    /// `neckRadius` and `markScale` are fractions of stature.
    init(stature: Double, facingLock: SIMD3<Double>?, skin: SCNMaterial, feature: SCNMaterial,
         skullOpacity: CGFloat = 1, neckRadius: Double = 0.040, markScale: Double = 1) {
        self.stature = stature
        self.facingLock = facingLock
        let S = stature

        let sphere = SCNSphere(radius: 1)         // unit; the node's transform makes it the ellipsoid
        sphere.segmentCount = 24
        sphere.materials = [skin]
        skull.geometry = sphere
        skull.opacity = skullOpacity
        root.addChildNode(skull)

        let neckGeometry = SCNCapsule(capRadius: CGFloat(neckRadius * S), height: 1)
        neckGeometry.radialSegmentCount = 12
        neckGeometry.materials = [skin]
        neck.geometry = neckGeometry
        root.addChildNode(neck)

        func mark(_ node: SCNNode, radius: Double) {
            let g = SCNSphere(radius: CGFloat(radius * S))
            g.segmentCount = 12
            g.materials = [feature]
            node.geometry = g
            node.isHidden = true
            root.addChildNode(node)
        }
        mark(nose, radius: 0.013 * markScale)
        mark(eyeLeft, radius: 0.0095 * markScale)
        mark(eyeRight, radius: 0.0095 * markScale)
        let chinGeometry = SCNCapsule(capRadius: CGFloat(0.0065 * markScale * S), height: 1)
        chinGeometry.radialSegmentCount = 8
        chinGeometry.materials = [feature]
        chin.geometry = chinGeometry
        chin.isHidden = true
        root.addChildNode(chin)
        root.isHidden = true
    }

    /// Body-frame nose, neck and mid-hip for one instant. Any of the three missing hides what cannot
    /// be placed rather than guessing it.
    func update(nose n: SIMD3<Double>?, neck k: SIMD3<Double>?, midHip: SIMD3<Double>?, opacity: CGFloat) {
        guard let n else { root.isHidden = true; return }
        root.isHidden = false
        root.opacity = opacity
        let trunkUp: SIMD3<Double>? = (k != nil && midHip != nil) ? (k! - midHip!) : nil
        let h = HeadGeometry.frame(nose: n, neck: k, trunkUp: trunkUp, stature: stature, facingLock: facingLock)
        faceUnavailableReason = h.faceUnavailableReason

        // The skull: a unit sphere taken onto the head's own axes. Columns are (side, up, forward),
        // each scaled by its semi-axis, so the ellipsoid is longer front-to-back than it is wide.
        let up = SceneBodyMath.simdPoint(h.up)
        let fwd = h.forward.map { SceneBodyMath.simdPoint($0) } ?? anyPerpendicular(to: up)
        let side = h.side.map { SceneBodyMath.simdPoint($0) } ?? simd_normalize(simd_cross(up, fwd))
        let c = SceneBodyMath.simdPoint(h.skullCentre)
        skull.simdTransform = simd_float4x4(
            SIMD4(side * Float(h.semiAxes.x), 0),
            SIMD4(up * Float(h.semiAxes.y), 0),
            SIMD4(fwd * Float(h.semiAxes.z), 0),
            SIMD4(c, 1))

        // The neck runs to where the skull actually starts, not to the nose.
        if let k {
            neck.isHidden = false
            SceneBodyMath.align(neck, from: k, to: h.skullBase, stretchingUnitHeight: true)
        } else {
            neck.isHidden = true
        }

        nose.isHidden = h.forward == nil
        nose.simdPosition = SceneBodyMath.simdPoint(h.nose)
        if let l = h.eyeLeft, let r = h.eyeRight {
            eyeLeft.isHidden = false; eyeRight.isHidden = false
            eyeLeft.simdPosition = SceneBodyMath.simdPoint(l)
            eyeRight.simdPosition = SceneBodyMath.simdPoint(r)
        } else {
            eyeLeft.isHidden = true; eyeRight.isHidden = true
        }
        if let a = h.chinLeft, let b = h.chinRight {
            chin.isHidden = false
            SceneBodyMath.align(chin, from: a, to: b, stretchingUnitHeight: true)
        } else {
            chin.isHidden = true
        }
    }

    func hide() { root.isHidden = true }

    private func anyPerpendicular(to v: SIMD3<Float>) -> SIMD3<Float> {
        let a = abs(v.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        let c = simd_cross(v, a)
        return simd_length(c) > 1e-6 ? simd_normalize(c) : SIMD3<Float>(0, 0, 1)
    }

    /// The same lock from a list of (nose, neck, mid-hip) triples — the form viewer's samples.
    static func facingLock(samples: [(nose: SIMD3<Double>, neck: SIMD3<Double>?, midHip: SIMD3<Double>?)],
                           stature: Double) -> SIMD3<Double>? {
        let usable: [(nose: SIMD3<Double>, neck: SIMD3<Double>, up: SIMD3<Double>)] = samples.compactMap {
            guard let k = $0.neck else { return nil }
            return ($0.nose, k, $0.midHip.map { h in k - h } ?? SIMD3(0, 0, 1))
        }
        return HeadGeometry.facingLock(noseNeckUp: usable, stature: stature)
    }

    /// The shot's own facing direction, so the head never flips between frames. Nil when no frame's
    /// nose cleared the jitter floor — and then no frame draws a face.
    static func facingLock(_ shot: BodyShot, stature: Double) -> SIMD3<Double>? {
        var samples: [(nose: SIMD3<Double>, neck: SIMD3<Double>, up: SIMD3<Double>)] = []
        for f in shot.frames {
            guard let n = f.fitted3D[SceneBodyJoints.centerHead].map({ SIMD3($0.x, $0.y, $0.z) }),
                  let k = f.fitted3D[SceneBodyJoints.centerShoulder].map({ SIMD3($0.x, $0.y, $0.z) }) else { continue }
            let hip = f.fitted3D[SceneBodyJoints.root].map { SIMD3($0.x, $0.y, $0.z) }
            samples.append((n, k, hip.map { k - $0 } ?? SIMD3(0, 0, 1)))
        }
        return HeadGeometry.facingLock(noseNeckUp: samples, stature: stature)
    }
}

// MARK: - The body

/// The proportioned body. Geometry is built once from the file's own segment lengths; `update(frame:)`
/// only writes transforms and opacities, so a 223-frame shot plays without touching the scene graph.
@MainActor
final class SceneBodyRig {
    let root = SCNNode()
    let proportions: SceneBodyProportions

    private let symmetryInferred: Set<String>
    private let shootingSide: String?
    private var jointNodes: [String: SCNNode] = [:]
    /// Drawn segments: the node, its two joints, and the joint distance its geometry was built for
    /// (the file's median). At playback the geometry is scaled along its own axis by the frame's
    /// actual joint distance over that nominal one, so a bone always runs joint to joint: a capsule
    /// of fixed length centred between two joints that have drifted apart (or together) is an arm
    /// that leaves its body, which is what iteration 3 drew.
    private var segmentNodes: [(node: SCNNode, a: String, b: String, nominal: Double)] = []
    private var head: SceneHeadRig!
    private var hands: [String: SceneHandRig] = [:]     // by "leftWrist" / "rightWrist"
    private var feet: [String: SceneFootRig] = [:]      // by "leftAnkle" / "rightAnkle"
    /// Nil while the head is drawn with a face; otherwise the sentence the legend prints instead.
    var headFaceUnavailableReason: String? { head?.faceUnavailableReason }
    private let stature: Double

    /// `symmetryInferred` joints are never drawn solid; a joint the file does not carry is not drawn.
    init(shot: BodyShot, proportions: SceneBodyProportions, palette: SceneBodyPalette = .standard) {
        self.proportions = proportions
        self.stature = proportions.stature
        self.symmetryInferred = Set(shot.symmetryInferred)
        self.shootingSide = shot.shootingSide

        func material(_ colour: SBColor) -> SCNMaterial {
            let m = SCNMaterial()
            m.diffuse.contents = colour
            m.lightingModel = .physicallyBased
            m.roughness.contents = 0.62
            m.metalness.contents = 0.0
            return m
        }
        let neutral = material(palette.neutral)
        let shooting = material(palette.shooting)
        let guideArm = material(palette.guideArm)
        func armMaterial(_ side: String) -> SCNMaterial {
            guard let s = shootingSide else { return neutral }
            return side == s ? shooting : guideArm
        }

        let S = stature
        func len(_ name: String, _ fallback: Double) -> Double { proportions.length(name) ?? fallback }

        // ---- torso: two rounded boxes, hips → spine → neck base ----
        // Widths are drawn proportions floored at an adult's: a near-side view cannot see the
        // shoulder line's depth, so the fit's biacromial is a lower bound, not a width.
        let hipWidth = max(len("biiliac", 0.16 * S), 0.155 * S) * 1.22
        let shoulderWidth = max(len("biacromial", 0.23 * S), 0.225 * S) * 1.12
        // The two boxes are built a fifth taller than their segments so they overlap at the spine:
        // a torso with a seam in it reads as two parts, and the shooter has one trunk.
        let pelvisLength = len("pelvis", 0.13 * S), chestLength = len("chest", 0.18 * S)
        let pelvis = box(width: hipWidth, depth: hipWidth * 0.68,
                         height: pelvisLength * 1.25, chamfer: 0.035 * S, material: neutral)
        addSegment(pelvis, SceneBodyJoints.root, SceneBodyJoints.spine, nominal: pelvisLength)
        let chest = box(width: shoulderWidth * 0.86, depth: shoulderWidth * 0.52,
                        height: chestLength * 1.20, chamfer: 0.045 * S, material: neutral)
        addSegment(chest, SceneBodyJoints.spine, SceneBodyJoints.centerShoulder, nominal: chestLength)

        // Shoulder and hip bars round the torso off at the joints.
        addSegment(capsule(radius: 0.055 * S, height: len("biacromial", 0.23 * S), material: neutral),
                   "leftShoulder", "rightShoulder", nominal: len("biacromial", 0.23 * S))
        addSegment(capsule(radius: 0.058 * S, height: len("biiliac", 0.16 * S), material: neutral),
                   "leftHip", "rightHip", nominal: len("biiliac", 0.16 * S))

        // ---- neck and head ----
        // Both belong to `SceneHeadRig`: the neck has to stop where the skull starts, and the skull
        // has to sit behind the nose rather than on it, so the two cannot be built independently.
        let feature = material(palette.feature)
        head = SceneHeadRig(stature: S, facingLock: SceneHeadRig.facingLock(shot, stature: S),
                            skin: neutral, feature: feature)
        root.addChildNode(head.root)

        // ---- limbs: radii scale with the shooter's own segment lengths ----
        for side in ["left", "right"] {
            let upper = len("upperArm" + side.capitalizedFirst, 0.19 * S)
            let fore = len("forearm" + side.capitalizedFirst, 0.16 * S)
            let thigh = len("thigh" + side.capitalizedFirst, 0.25 * S)
            let shin = len("shin" + side.capitalizedFirst, 0.24 * S)
            let m = armMaterial(side)
            addSegment(capsule(radius: 0.150 * upper, height: upper, material: m),
                       side + "Shoulder", side + "Elbow", nominal: upper)
            addSegment(capsule(radius: 0.118 * fore, height: fore, material: m),
                       side + "Elbow", side + "Wrist", nominal: fore)
            addSegment(capsule(radius: 0.190 * thigh, height: thigh, material: neutral),
                       side + "Hip", side + "Knee", nominal: thigh)
            addSegment(capsule(radius: 0.140 * shin, height: shin, material: neutral),
                       side + "Knee", side + "Ankle", nominal: shin)
            let rig = SceneHandRig(stature: S, material: m)
            hands[side + "Wrist"] = rig
            root.addChildNode(rig.root)
            let foot = SceneFootRig(stature: S, material: neutral)
            feet[side + "Ankle"] = foot
            root.addChildNode(foot.root)
        }

        // ---- joints, sized off the segments that meet there ----
        let jointRadius: [String: Double] = [
            "leftShoulder": 0.062, "rightShoulder": 0.062,
            "leftElbow": 0.030, "rightElbow": 0.030,
            "leftWrist": 0.021, "rightWrist": 0.021,
            "leftHip": 0.055, "rightHip": 0.055,
            "leftKnee": 0.050, "rightKnee": 0.050,
            "leftAnkle": 0.034, "rightAnkle": 0.034,
        ]
        for (name, r) in jointRadius {
            let s = SCNSphere(radius: CGFloat(r * S))
            s.segmentCount = 12
            s.materials = [name.hasSuffix("Shoulder") || name.hasSuffix("Elbow") || name.hasSuffix("Wrist")
                           ? armMaterial(String(name.prefix(while: { $0.isLowercase }))) : neutral]
            let node = SCNNode(geometry: s)
            node.isHidden = true
            root.addChildNode(node)
            jointNodes[name] = node
        }
    }

    // MARK: Building blocks

    private func capsule(radius: Double, height: Double, material: SCNMaterial) -> SCNNode {
        let c = SCNCapsule(capRadius: CGFloat(max(radius, 0.001)), height: CGFloat(max(height, 0.002)))
        c.radialSegmentCount = 12
        c.materials = [material]
        return SCNNode(geometry: c)
    }

    private func box(width: Double, depth: Double, height: Double, chamfer: Double, material: SCNMaterial) -> SCNNode {
        // Scene axes: x across the body, y up (the segment's own axis), z toward the rim.
        let b = SCNBox(width: CGFloat(max(width, 0.01)), height: CGFloat(max(height, 0.01)),
                       length: CGFloat(max(depth, 0.01)), chamferRadius: CGFloat(max(chamfer, 0.001)))
        b.materials = [material]
        return SCNNode(geometry: b)
    }

    private func addSegment(_ node: SCNNode, _ a: String, _ b: String, nominal: Double) {
        node.isHidden = true
        root.addChildNode(node)
        segmentNodes.append((node, a, b, max(nominal, 1e-4)))
    }

    // MARK: Playback

    /// Move the body onto one frame. Nothing is rebuilt: 35-odd transforms and opacities.
    func update(frame: BodyShotFrame) {
        func p(_ j: String) -> SIMD3<Double>? { frame.fitted3D[j].map { SIMD3($0.x, $0.y, $0.z) } }

        /// 1 solid, 0.55 not seen this frame, 0.3 mirrored from the other side of the body.
        func opacity(_ j: String) -> CGFloat {
            if symmetryInferred.contains(j) || symmetryInferred.contains(SceneBodyJoints.seenKey(j)) { return 0.30 }
            if frame.seen[SceneBodyJoints.seenKey(j)] == false { return 0.55 }
            return 1.0
        }

        for (name, node) in jointNodes {
            guard let q = p(name) else { node.isHidden = true; continue }
            node.isHidden = false
            node.position = SceneBodyMath.scenePoint(q)
            node.opacity = opacity(name)
        }

        for seg in segmentNodes {
            guard let a = p(seg.a), let b = p(seg.b) else { seg.node.isHidden = true; continue }
            let len = SceneBodyMath.align(seg.node, from: a, to: b)
            guard len > 0 else { seg.node.isHidden = true; continue }
            // Joint to joint, whatever the frame's distance: the geometry is built for the file's
            // median distance and stretched (or shrunk) along its own axis by the ratio.
            seg.node.simdScale = SIMD3<Float>(1, len / Float(seg.nominal), 1)
            seg.node.isHidden = false
            seg.node.opacity = min(opacity(seg.a), opacity(seg.b))
        }

        head.update(nose: p(SceneBodyJoints.centerHead), neck: p(SceneBodyJoints.centerShoulder),
                    midHip: p(SceneBodyJoints.root),
                    opacity: min(opacity(SceneBodyJoints.centerHead), opacity(SceneBodyJoints.centerShoulder)))

        updateHands(frame: frame)
        SceneFootRig.update(feet, frame: frame)
    }

    private func updateHands(frame: BodyShotFrame) {
        var used = Set<String>()
        // The fitted plates first (1.3). A plate is a 3-D orientation and beats the flat finger
        // drawing, which is 2-D by construction; a hand with only two confident points has no
        // orientation and falls through to the flat fingers below, exactly as before.
        for t in frame.handTriangles ?? [] {
            let key = t.side + "Wrist"
            guard t.pointsUsed >= 3, let rig = hands[key] else { continue }
            rig.showPlate(t, certain: t.interpolated.isEmpty && t.clamped.isEmpty)
            used.insert(key)
        }
        for side in ["leftWrist", "rightWrist"] where !used.contains(side) { hands[side]?.hidePlate() }
        // Attach each detected hand to the wrist it is actually nearest in the image: the file's
        // chirality is not always given, and a role is not a position.
        if let uSign = proportions.imageURunsWithBodyX {
            let palm = 0.055 * stature
            for hand in frame.hands {
                guard let w = hand.landmarks["wrist"], let mcp = hand.landmarks["middleMCP"] else { continue }
                let px = hypot(mcp.u - w.u, mcp.v - w.v)
                guard px > 1 else { continue }
                var best: (String, Double)?
                for side in ["leftWrist", "rightWrist"] {
                    guard !used.contains(side), let q = frame.points2D[side] else { continue }
                    let d = hypot(q.u - w.u, q.v - w.v)
                    if best == nil || d < best!.1 { best = (side, d) }
                }
                // A hand more than three palms from the wrist is not that wrist's hand.
                guard let (side, distance) = best, distance < px * 3, let rig = hands[side],
                      let wrist3D = frame.fitted3D[side].map({ SIMD3($0.x, $0.y, $0.z) }) else { continue }
                rig.showFingers(hand.landmarks, wrist3D: wrist3D, scale: palm / px, uSign: uSign)
                used.insert(side)
            }
        }
        for side in ["left", "right"] {
            let key = side + "Wrist"
            guard !used.contains(key), let rig = hands[key] else { continue }
            guard let wrist3D = frame.fitted3D[key].map({ SIMD3($0.x, $0.y, $0.z) }) else { rig.hide(); continue }
            rig.showMitt(wrist3D: wrist3D,
                         elbow3D: frame.fitted3D[side + "Elbow"].map { SIMD3($0.x, $0.y, $0.z) },
                         stature: stature)
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - The scene around it

/// Camera presets live in `FormCameraPresets.swift` now (1.2, item 21), so the skeleton viewer and
/// this body player put the camera in exactly the same places. The old name still works.
typealias SceneBodyCamera = FormCameraPreset

/// Scene, lights, floor grid, rim marker and the body. Everything static is built once.
@MainActor
final class SceneBodyScene {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    let contentNode = SCNNode()
    let body: SceneBodyRig
    let proportions: SceneBodyProportions
    /// What the rim marker means on this file — it is a bearing, and sometimes not even that.
    let rimNote: String

    init(shot: BodyShot, palette: SceneBodyPalette = .standard, background: SBColor? = nil) {
        let props = SceneBodyProportions.measure(shot)
        self.proportions = props
        self.body = SceneBodyRig(shot: shot, proportions: props, palette: palette)

        if let background { scene.background.contents = background }
        scene.rootNode.addChildNode(contentNode)
        contentNode.addChildNode(body.root)

        let S = props.stature
        // ---- floor grid at the ankles' lowest point ----
        let grid = SCNNode()
        let half = 0.95 * S, step = 0.19 * S
        let lineMaterial = SCNMaterial()
        lineMaterial.diffuse.contents = palette.grid
        lineMaterial.lightingModel = .constant
        lineMaterial.transparency = 0.42
        var t = -half
        while t <= half + 1e-9 {
            for axis in 0..<2 {
                let a = axis == 0 ? SIMD3(t, -half, props.floorHeight) : SIMD3(-half, t, props.floorHeight)
                let b = axis == 0 ? SIMD3(t, half, props.floorHeight) : SIMD3(half, t, props.floorHeight)
                let g = SCNBox(width: CGFloat(0.004 * S), height: 1, length: CGFloat(0.004 * S), chamferRadius: 0)
                g.materials = [lineMaterial]
                let n = SCNNode(geometry: g)
                SceneBodyMath.align(n, from: a, to: b, stretchingUnitHeight: true)
                grid.addChildNode(n)
            }
            t += step
        }
        contentNode.addChildNode(grid)

        // ---- the rim direction: the body frame's +x ----
        let rimMaterial = SCNMaterial()
        rimMaterial.diffuse.contents = palette.rim
        rimMaterial.lightingModel = .physicallyBased
        rimMaterial.roughness.contents = 0.5
        let z = props.floorHeight + 0.05 * S
        let shaft = SCNCapsule(capRadius: CGFloat(0.014 * S), height: 1)
        shaft.materials = [rimMaterial]
        let shaftNode = SCNNode(geometry: shaft)
        SceneBodyMath.align(shaftNode, from: SIMD3(0.45 * S, 0, z), to: SIMD3(0.80 * S, 0, z),
                            stretchingUnitHeight: true)
        contentNode.addChildNode(shaftNode)
        let cone = SCNCone(topRadius: 0, bottomRadius: CGFloat(0.040 * S), height: CGFloat(0.10 * S))
        cone.materials = [rimMaterial]
        let coneNode = SCNNode(geometry: cone)
        SceneBodyMath.align(coneNode, from: SIMD3(0.80 * S, 0, z), to: SIMD3(0.89 * S, 0, z))
        contentNode.addChildNode(coneNode)

        let facing = shot.conventions["body"] ?? ""
        if facing.contains("nothing was supplied about where the rim is") {
            rimNote = "The green arrow is the body frame's +x. On this file that is the camera's own right, not the rim: nothing was supplied about where the rim was."
        } else if facing.contains("toward the rim") {
            rimNote = "The green arrow points at the rim: the body frame's +x, from the rim's image column. It is a bearing, not a distance."
        } else {
            rimNote = "The green arrow is the body frame's +x."
        }

        // ---- lights ----
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 750
        key.simdPosition = SIMD3<Float>(2, 4, 3)
        key.simdLook(at: .zero)
        scene.rootNode.addChildNode(key)
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.intensity = 300
        fill.simdPosition = SIMD3<Float>(-3, 2, -2)
        fill.simdLook(at: .zero)
        scene.rootNode.addChildNode(fill)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 420
        scene.rootNode.addChildNode(ambient)

        let camera = SCNCamera()
        camera.fieldOfView = 38
        camera.zNear = 0.001
        camera.zFar = 500
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        apply(.side)
    }

    /// The point the camera looks at: the middle of the body over the whole shot.
    var target: SIMD3<Float> { SIMD3<Float>(0, Float(proportions.midHeight), 0) }

    /// Scene y of the floor — the ankles' lowest point, which is where the grid was drawn.
    var floorSceneHeight: Float { Float(proportions.floorHeight) }

    /// Scene y of the rim, but **only** when the file carries metres. Without a stated standing
    /// height the body is drawn at its own unit scale and there is no honest metre to put a rim at;
    /// the rim's-eye preset then falls back to a stature multiple and says so.
    var rimSceneHeight: Float? {
        proportions.unit == "metres"
            ? floorSceneHeight + Float(FormCameraPreset.rimHeightMetres)
            : nil
    }

    /// Scene-space camera positions. Scene x is across the body, y up, z toward the rim.
    func apply(_ preset: SceneBodyCamera) {
        guard let pose = preset.pose(stature: proportions.stature, target: target,
                                     floorSceneHeight: floorSceneHeight, rimSceneHeight: rimSceneHeight)
        else { return }
        cameraNode.simdPosition = pose.position
        cameraNode.simdLook(at: pose.target)
    }
}

// MARK: - Playback arithmetic (no SceneKit, so the tests and the harness can use it)

/// Times, phases and angle lookups over one `BodyShot`. Everything is the file's own clock: the
/// frames' `t_real`, and phase times the export already vetted. Nothing is interpolated into a
/// phase the file refused — the reason travels instead.
struct BodyShotPlayback: Sendable {
    let times: [Double]
    let releaseRealTime: Double
    let frameStep: Double
    let phases: [Phase]

    struct Phase: Sendable, Identifiable {
        var name: String
        var realTime: Double?
        var unavailableReason: String?
        var id: String { name }
    }

    init(_ shot: BodyShot) {
        times = shot.frames.map(\.t_real).sorted()
        releaseRealTime = shot.timing.releaseRealTime
        let fps = shot.source.format.fps
        frameStep = fps > 0 ? Double(max(1, shot.timing.everyNthFrame)) / fps : shot.timing.quantisationFloor
        phases = [
            Phase(name: "Set", realTime: shot.timing.set.value, unavailableReason: shot.timing.set.unavailableReason),
            Phase(name: "Dip", realTime: shot.timing.dip.value, unavailableReason: shot.timing.dip.unavailableReason),
            Phase(name: "Release", realTime: shot.timing.releaseRealTime, unavailableReason: nil),
            Phase(name: "Follow-through", realTime: shot.timing.followThroughPeak.value,
                  unavailableReason: shot.timing.followThroughPeak.unavailableReason),
        ]
    }

    var first: Double { times.first ?? releaseRealTime }
    var last: Double { times.last ?? releaseRealTime }
    var duration: Double { max(1e-6, last - first) }
    var count: Int { times.count }

    /// The frame nearest a real time. Binary search: this runs on every tick.
    func index(atRealTime t: Double) -> Int {
        guard !times.isEmpty else { return 0 }
        var lo = 0, hi = times.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, abs(times[lo - 1] - t) <= abs(times[lo] - t) { return lo - 1 }
        return lo
    }

    var releaseIndex: Int { index(atRealTime: releaseRealTime) }

    /// Seconds from release, the only phase clock this screen shows.
    func secondsFromRelease(_ t: Double) -> Double { t - releaseRealTime }

    /// 0…1 along the file's own frames, for the scrubber.
    func fraction(ofIndex i: Int) -> Double {
        guard times.count > 1 else { return 0 }
        return Double(i) / Double(times.count - 1)
    }
}

extension BodyShot {

    /// The angle track's value at a real time, in **degrees** (the boundary), or nil with the track's
    /// own reason. A sample more than one-and-a-half frame steps away is not this frame's angle.
    func angleDegrees(_ track: String, atRealTime t: Double, tolerance: Double) -> (degrees: Double?, reason: String?) {
        guard let a = angles[track] else { return (nil, "this file carries no \(track) track") }
        if let reason = a.unavailableReason, a.samples.isEmpty { return (nil, reason) }
        guard let s = a.samples.min(by: { abs($0.t_real - t) < abs($1.t_real - t) }) else {
            return (nil, a.unavailableReason ?? "no samples in this track")
        }
        guard abs(s.t_real - t) <= tolerance else {
            return (nil, "no sample within one frame of this instant")
        }
        return (s.radians * 180 / .pi, nil)
    }
}
