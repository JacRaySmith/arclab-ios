import Foundation
import SceneKit
import simd
import ShotGeometry

// ================================================================================================
// MARK: - Foot plates (1.3 Track C, 2026-09-16)
// ================================================================================================
//
// The feet, drawn the way the hands are drawn: an oriented triangle — heel · big toe · little toe —
// filled at the foot's own colour, with a short spine along the foot's pointing direction so the
// plate reads as a foot and not as a lozenge.
//
// This lives in its own file so Track B (hands) and Track C (feet) could be written at the same time
// without touching each other's code. **Two hook lines put it on screen**, both in
// `App/Sources/SceneBody.swift` and both additive:
//
//   1. in `SceneBodyRig.init`, alongside `let rig = SceneHandRig(stature: S, material: m)`:
//          let foot = SceneFootRig(stature: S, material: neutral)
//          feet[side + "Ankle"] = foot
//          root.addChildNode(foot.root)
//      with `private var feet: [String: SceneFootRig] = [:]` next to `hands`;
//   2. at the end of `update(frame:)`, on the line after `updateHands(frame: frame)`:
//          SceneFootRig.update(feet, frame: frame)
//
// That is the whole integration. Everything else — geometry, hiding, the confidence rule — is here.
//
// Until `BodyShotExport.swift` carries `footTriangles` (the two-line edit named in
// `FootKinematics.swift`'s own header), `SceneFootRig.update` finds an empty array and draws
// nothing, which is the right behaviour for a shot analysed before the feet existed.

/// One foot's plate. Built once; playback only swaps the triangle's three vertices.
@MainActor
final class SceneFootRig {
    let root = SCNNode()
    private let plate = SCNNode()
    private let spine = SCNNode()
    private let plateMaterial = SCNMaterial()
    private let spineMaterial = SCNMaterial()
    private let colour: SBColor
    private let stature: Double

    init(stature: Double, material: SCNMaterial) {
        self.stature = stature
        self.colour = (material.diffuse.contents as? SBColor) ?? SBColor.white

        plateMaterial.diffuse.contents = colour.withAlphaComponent(0.55)
        plateMaterial.lightingModel = .constant
        plateMaterial.isDoubleSided = true
        plate.isHidden = true
        root.addChildNode(plate)

        spineMaterial.diffuse.contents = colour.withAlphaComponent(0.85)
        spineMaterial.lightingModel = .constant
        let c = SCNCapsule(capRadius: CGFloat(0.0045 * stature), height: 1)
        c.radialSegmentCount = 6
        c.materials = [spineMaterial]
        spine.geometry = c
        spine.isHidden = true
        root.addChildNode(spine)
    }

    func hide() {
        plate.isHidden = true
        spine.isHidden = true
    }

    /// Draw the plate for one frame.
    ///
    /// `certain` is false when a vertex was clamped onto the size prior's sphere, or when the roll
    /// was refused because the two toes were too close together in the image — the two cases where
    /// the *shape* on screen is doing more work than the measurement behind it. The plate is then
    /// drawn faint, and the legend should say why; it is never hidden, because the foot was still
    /// seen and hiding it would read as "no foot".
    func show(_ t: BodyShotFootTriangle) {
        guard let h = t.heel, let b = t.bigToe, let l = t.littleToe, t.pointsUsed >= 3 else {
            // Two points: a pointing direction and no plate. Draw the spine alone — an honest
            // "this is where the foot points, and nothing is claimed about its roll".
            if let h = t.heel, let tip = t.bigToe ?? t.littleToe {
                plate.isHidden = true
                showSpine(from: SIMD3(h.x, h.y, h.z), to: SIMD3(tip.x, tip.y, tip.z), faint: true)
            } else {
                hide()
            }
            return
        }
        let certain = t.clamped.isEmpty && t.roll.value != nil
        plateMaterial.diffuse.contents = colour.withAlphaComponent(certain ? 0.55 : 0.22)
        plate.geometry = SceneBodyMath.triangle(SIMD3(h.x, h.y, h.z), SIMD3(b.x, b.y, b.z),
                                                SIMD3(l.x, l.y, l.z), material: plateMaterial)
        plate.isHidden = false
        showSpine(from: SIMD3(h.x, h.y, h.z),
                  to: SIMD3((b.x + l.x) / 2, (b.y + l.y) / 2, (b.z + l.z) / 2),
                  faint: !certain)
    }

    private func showSpine(from a: SIMD3<Double>, to b: SIMD3<Double>, faint: Bool) {
        spineMaterial.diffuse.contents = colour.withAlphaComponent(faint ? 0.35 : 0.85)
        guard SceneBodyMath.align(spine, from: a, to: b, stretchingUnitHeight: true) > 0 else {
            spine.isHidden = true; return
        }
        spine.isHidden = false
    }

    /// The whole per-frame hook: one call from `SceneBodyRig.update(frame:)`.
    static func update(_ feet: [String: SceneFootRig], frame: BodyShotFrame) {
        var used = Set<String>()
        for t in frame.footTrianglesIfPresent {
            let key = t.side + "Ankle"
            guard let rig = feet[key] else { continue }
            rig.show(t)
            used.insert(key)
        }
        for key in ["leftAnkle", "rightAnkle"] where !used.contains(key) { feet[key]?.hide() }
    }
}

extension BodyShotFrame {
    /// Bridges the gap until `BodyShotExport.swift` carries the field. Once it does, this becomes
    /// `footTriangles ?? []` and the shim is deleted — it is one line, and it is here rather than in
    /// the export so that two agents could work on the export and the drawing at the same time.
    var footTrianglesIfPresent: [BodyShotFootTriangle] { footTriangles ?? [] }
}
