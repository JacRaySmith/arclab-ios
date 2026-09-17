import Foundation
import simd

// ================================================================================================
// MARK: - Where the skull sits, and which way the face points
// ================================================================================================
//
// The fit solves for one head joint and it is the **nose** (`BodySkeletonFit` writes the 2-D `nose`
// out under the 3-D name `centerHead`). Drawing a sphere on that point puts the ball of the head in
// front of the face, which is what iterations 1–4 drew and what the user reported as "the head is
// messed up". A head that reads as a head needs three things this file computes and nothing else:
//
//   1. a **skull** ellipsoid seated on the neck, with the nose on its front surface rather than at
//      its centre — so the mass of the head is behind the face, where a head's mass is;
//   2. a **facing direction**, which is the one thing that says which way the shooter is looking;
//   3. **face marks** — two eyes and a chin line — drawn only when 2 is available.
//
// Every length here is a fraction of the shooter's own stature, taken from standard adult head
// anthropometry (head height ≈ 0.130 H, breadth ≈ 0.084 H, depth ≈ 0.105 H, interpupillary
// ≈ 0.036 H). They are **drawn proportions, not measurements**: a single camera does not measure a
// skull, and the viewers say so. What *is* measured is the nose, the neck and the facing sign; the
// proportions only decide how to dress them.
//
// Foundation + simd only, and pure, so the geometry is tested without a scene graph.

/// Adult head proportions as fractions of standing height. Drawn proportions, not measurements.
public enum HeadProportions {
    /// Semi-axis across the head (half the head's breadth).
    public static let semiSide = 0.042
    /// Semi-axis along the head's own up axis (half its chin-to-vertex height).
    public static let semiUp = 0.065
    /// Semi-axis front-to-back (half glabella-to-occiput).
    public static let semiForward = 0.0525
    /// How far behind the nose tip the skull's centre sits: the front semi-axis plus the nose's own
    /// protrusion past the face plane.
    public static let noseToCentre = 0.060
    /// The nose sits below the skull's mid-height by this much, so the brow is above it.
    public static let noseBelowCentre = 0.018
    /// Half the interpupillary distance.
    public static let halfEyeSpan = 0.018
    /// Eyes: this far forward of the skull centre and this far above it.
    public static let eyeForward = 0.040
    public static let eyeUp = 0.020
    /// The chin line: this far forward of and below the skull centre, and this wide either side.
    public static let chinForward = 0.028
    public static let chinDown = 0.058
    public static let chinHalfWidth = 0.020
    /// Where the neck meets the skull.
    public static let baseDown = 0.060
    /// A horizontal nose-past-the-neck offset smaller than this is inside the keypoint jitter and
    /// says nothing about which way the shooter faces. The measured median over 110 phone shots is
    /// 0.037 H, so this refuses roughly the bottom third of it rather than the typical case.
    public static let minimumFacingOffset = 0.012
}

/// The head's own frame on one instant, plus the marks a viewer draws on it.
///
/// Positions are in whatever frame the joints came in (the app's body frame: x toward the rim,
/// y across the body, z up) and in whatever length unit they carry (metres, or stature units).
public struct HeadFrame: Sendable, Equatable {
    /// The measured nose — the fit's only head joint.
    public var nose: SIMD3<Double>
    /// Centre of the skull ellipsoid.
    public var skullCentre: SIMD3<Double>
    /// Where the neck meets the skull: a neck drawn to here meets a head, not a nose.
    public var skullBase: SIMD3<Double>
    /// Orthonormal head axes. `up` is always available (the trunk gives it); `forward` and `side`
    /// are nil exactly when `faceUnavailableReason` is set.
    public var up: SIMD3<Double>
    public var forward: SIMD3<Double>?
    public var side: SIMD3<Double>?
    /// Skull semi-axes along (side, up, forward), in the joints' own unit.
    public var semiAxes: SIMD3<Double>
    /// Face marks, nil together with `forward`.
    public var eyeLeft: SIMD3<Double>?
    public var eyeRight: SIMD3<Double>?
    public var chinLeft: SIMD3<Double>?
    public var chinRight: SIMD3<Double>?
    /// Nil when a face may be drawn; otherwise the sentence the legend prints instead of a face.
    public var faceUnavailableReason: String?
    /// The measured horizontal nose-past-the-neck offset, in the joints' unit. The evidence behind
    /// `forward`, so a viewer can show it.
    public var facingOffset: Double
}

public enum HeadGeometry {

    /// The shooter's facing direction on one instant: the horizontal part of neck → nose.
    ///
    /// This is the same cue `BodyFacing` takes from the image, read off the fitted skeleton instead,
    /// so the drawn face can never disagree with the drawn body. Nil when the offset is inside the
    /// jitter floor — a nose directly over its own neck says nothing about where the shooter looks.
    public static func facing(nose: SIMD3<Double>, neck: SIMD3<Double>, up: SIMD3<Double>,
                              stature: Double,
                              minimumOffsetFraction: Double = HeadProportions.minimumFacingOffset)
        -> (direction: SIMD3<Double>, offset: Double)? {
        let u = simd_length(up) > 1e-9 ? simd_normalize(up) : SIMD3<Double>(0, 0, 1)
        let d = nose - neck
        let horizontal = d - simd_dot(d, u) * u
        let offset = simd_length(horizontal)
        guard stature > 1e-9, offset >= minimumOffsetFraction * stature else { return nil }
        return (horizontal / offset, offset)
    }

    /// The head's frame on one instant.
    ///
    /// - `facingLock`: the shot's own median facing direction. A head does not turn round inside a
    ///   shot, so the per-frame direction is projected onto the lock's half-space; without it a
    ///   noisy frame can flip the face by 180° and the head appears to spin.
    /// - `up`: the trunk's own axis (mid-hip → neck) when the caller has it, so the head leans with
    ///   the body. Falls back to the body frame's +z.
    public static func frame(nose: SIMD3<Double>, neck: SIMD3<Double>?, trunkUp: SIMD3<Double>?,
                             stature: Double, facingLock: SIMD3<Double>? = nil,
                             minimumOffsetFraction: Double = HeadProportions.minimumFacingOffset) -> HeadFrame {
        let S = max(stature, 1e-9)
        var up = SIMD3<Double>(0, 0, 1)
        if let t = trunkUp, simd_length(t) > 1e-9 { up = simd_normalize(t) }
        let semi = SIMD3(HeadProportions.semiSide * S, HeadProportions.semiUp * S, HeadProportions.semiForward * S)

        guard let neck else {
            // No neck joint: the skull can only be centred on the nose, and nothing says which way
            // it looks. Drawn as a bare skull with the nose at its front-bottom is not available
            // either, so it is centred and the caller is told why there is no face.
            return HeadFrame(nose: nose, skullCentre: nose, skullBase: nose - up * (HeadProportions.baseDown * S),
                             up: up, forward: nil, side: nil, semiAxes: semi,
                             eyeLeft: nil, eyeRight: nil, chinLeft: nil, chinRight: nil,
                             faceUnavailableReason: "this shot carries no neck joint, so the head has nothing to sit on and no facing direction: the skull is drawn centred on the measured nose and no face is drawn",
                             facingOffset: 0)
        }

        guard var f = facing(nose: nose, neck: neck, up: up, stature: S,
                             minimumOffsetFraction: minimumOffsetFraction).map({ (dir: $0.direction, offset: $0.offset) }) else {
            let d = nose - neck
            let horizontal = simd_length(d - simd_dot(d, up) * up)
            let centre = nose + (simd_length(d) > 1e-9 ? simd_normalize(d) : up) * (0.35 * semi.y)
            return HeadFrame(nose: nose, skullCentre: centre, skullBase: centre - up * (HeadProportions.baseDown * S),
                             up: up, forward: nil, side: nil, semiAxes: semi,
                             eyeLeft: nil, eyeRight: nil, chinLeft: nil, chinRight: nil,
                             faceUnavailableReason: String(format: "the nose sits only %.3f of a stature horizontally from the neck (floor %.3f), inside the keypoint jitter: this view does not say which way the shooter faces, so no face is drawn",
                                                           horizontal / S, minimumOffsetFraction),
                             facingOffset: horizontal)
        }
        if let facingLock, simd_length(facingLock) > 1e-9, simd_dot(f.dir, simd_normalize(facingLock)) < 0 {
            f.dir = -f.dir
        }
        let forward = f.dir
        // Right-handed anatomy: forward × left = up, so left = up × forward.
        var side = simd_cross(up, forward)
        if simd_length(side) < 1e-9 { side = SIMD3(0, 1, 0) } else { side = simd_normalize(side) }
        let centre = nose - forward * (HeadProportions.noseToCentre * S) + up * (HeadProportions.noseBelowCentre * S)
        let base = centre - up * (HeadProportions.baseDown * S)
        let eyeCentre = centre + forward * (HeadProportions.eyeForward * S) + up * (HeadProportions.eyeUp * S)
        let chinCentre = centre + forward * (HeadProportions.chinForward * S) - up * (HeadProportions.chinDown * S)
        return HeadFrame(nose: nose, skullCentre: centre, skullBase: base, up: up, forward: forward, side: side,
                         semiAxes: semi,
                         eyeLeft: eyeCentre + side * (HeadProportions.halfEyeSpan * S),
                         eyeRight: eyeCentre - side * (HeadProportions.halfEyeSpan * S),
                         chinLeft: chinCentre + side * (HeadProportions.chinHalfWidth * S),
                         chinRight: chinCentre - side * (HeadProportions.chinHalfWidth * S),
                         faceUnavailableReason: nil, facingOffset: f.offset)
    }

    /// `facingLock` for a whole shot: the mean of the per-frame directions, taken with each one
    /// flipped onto the first's half-space so a run of good frames is not cancelled by a flipped
    /// bad one. Nil when no frame cleared the jitter floor.
    public static func facingLock(noseNeckUp: [(nose: SIMD3<Double>, neck: SIMD3<Double>, up: SIMD3<Double>)],
                                  stature: Double,
                                  minimumOffsetFraction: Double = HeadProportions.minimumFacingOffset) -> SIMD3<Double>? {
        var reference: SIMD3<Double>? = nil
        var sum = SIMD3<Double>.zero
        var n = 0
        for s in noseNeckUp {
            guard let f = facing(nose: s.nose, neck: s.neck, up: s.up, stature: stature,
                                 minimumOffsetFraction: minimumOffsetFraction) else { continue }
            var d = f.direction
            if let r = reference { if simd_dot(d, r) < 0 { d = -d } } else { reference = d }
            sum += d
            n += 1
        }
        guard n > 0, simd_length(sum) > 1e-9 else { return nil }
        return simd_normalize(sum)
    }
}
