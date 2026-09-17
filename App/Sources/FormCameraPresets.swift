import SceneKit
import simd

// ================================================================================================
// MARK: - Camera presets for the 3-D form
// ================================================================================================
//
// Four named points of view and free orbit, shared by the skeleton viewer (`FormModelView`) and the
// body player (`BodyPlayerView`). The poses are written in **scene** coordinates, which are the body
// frame cycled once by `SceneBodyMath.scenePoint`:
//
//      scene x = body y  (across the body)
//      scene y = body z  (up)
//      scene z = body x  (toward the rim)
//
// so "side" is along the body's across-axis, "front" looks back down the rim axis, and "rim's-eye"
// is the same bearing raised to the rim's height. Distances are in statures, so the framing is the
// same whether the form is in metres or in shooter heights.
//
// Honesty: only the **bearing** in these presets is measured — the body frame's +x is the rim's
// direction when the clip had a rim in it, and the scene says so where it is not
// (`SceneBodyScene.rimNote`). The camera's *distance* from the shooter, and the rim's-eye height
// when the clip carries no metres, are drawing choices; `note` says that on screen.

struct FormCameraPose: Sendable {
    var position: SIMD3<Float>
    var target: SIMD3<Float>
}

enum FormCameraPreset: String, CaseIterable, Sendable {
    case side, front, above, rimEye, free

    var label: String {
        switch self {
        case .side: return "Side"
        case .front: return "Front"
        case .above: return "Above"
        case .rimEye: return "Rim's-eye"
        case .free: return "Free"
        }
    }

    /// Rulebook rim height, metres (docs/reference/sdk-and-licensing-research-2026-09-12.md).
    static let rimHeightMetres = 3.048
    /// Used only when the clip carries no metres: a rim is about this many statures up for a 1.78 m
    /// shooter. A drawing choice, and `note` says so.
    static let rimHeightStatures = 1.71

    /// Where the camera goes. `nil` for `.free`, which is whatever the viewer orbited to.
    ///
    /// - Parameters:
    ///   - stature: the shooter's standing height in the scene's own length unit.
    ///   - target: the point the camera looks at, in scene coordinates.
    ///   - floorSceneHeight: scene y of the floor, for the rim's-eye height.
    ///   - rimSceneHeight: scene y of the rim when it is known; otherwise the fallback above is used.
    func pose(stature: Double, target: SIMD3<Float>, floorSceneHeight: Float,
              rimSceneHeight: Float?) -> FormCameraPose? {
        let s = Float(max(stature, 1e-6))
        // 2.15 statures at a 38–40° field of view frames the whole body with room for the raised arm
        // on a phone-shaped viewport, which is what these are looked at on.
        let d = 2.15 * s
        switch self {
        case .side:
            return FormCameraPose(position: target + SIMD3<Float>(-d, 0.15 * s, 0.22 * s), target: target)
        case .front:
            return FormCameraPose(position: target + SIMD3<Float>(0.12 * s, 0.12 * s, d), target: target)
        case .above:
            return FormCameraPose(position: target + SIMD3<Float>(0.001 * s, 1.25 * d, 0.30 * s), target: target)
        case .rimEye:
            let y = rimSceneHeight ?? (floorSceneHeight + Float(Self.rimHeightStatures) * s)
            return FormCameraPose(position: SIMD3<Float>(target.x, y, target.z + 2.1 * s), target: target)
        case .free:
            return nil
        }
    }

    /// The one short sentence a preset's caption carries about the body frame's +x, from the form's
    /// own `facingNote`. Short on purpose: the full sentence is in the provenance card, and a caption
    /// nobody reads is worse than a caption that says the one thing the preset depends on.
    static func shortFacingNote(_ facingNote: String) -> String {
        if facingNote.contains("points at the rim") { return "+x points at the rim, from the shot plane." }
        if facingNote.contains("rim's image column") { return "+x is the bearing to the rim; the depth along it is the axis one camera cannot see." }
        if facingNote.contains("camera's own right") { return "+x is the camera's own right: this clip never said where the rim was." }
        return ""
    }

    /// The line under the picker. Every sentence here is about what is and is not measured.
    func note(rimNote: String) -> String {
        switch self {
        case .free:
            return "Drag to orbit, pinch to zoom. The presets are named against the body frame's +x."
        case .side:
            return "Across the body, from the shooter's non-rim side. " + rimNote
        case .front:
            return "Down the body frame's +x, level with the middle of the body. " + rimNote
        case .above:
            return "Straight down. The overhead view is the one a single camera never measured: depth toward the rim is the weakest axis of this fit."
        case .rimEye:
            return "From the rim's bearing, at the rulebook 3.05 m above the floor (1.71 statures where the clip carries no metres). The height is drawn and the distance is a drawing choice; only the direction is measured. " + rimNote
        }
    }
}
