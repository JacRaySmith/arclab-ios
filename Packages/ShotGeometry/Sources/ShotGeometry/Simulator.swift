import Foundation

/// World frame for simulation: origin at the rim centre, Z up, X from shooter toward rim, Y lateral.
public struct ShotParameters: Sendable {
    public var releaseAngle: Double        // rad above horizontal
    public var releaseSpeed: Double        // m/s
    public var releaseHeight: Double       // m above floor, ball centre
    public var releaseDistance: Double     // m, horizontal from release point to rim centre
    public var lateralOffset: Double = 0   // m, release point sideways from the rim's centreline
    public var lateralAimError: Double = 0 // rad, velocity yaw error

    public init(releaseAngle: Double, releaseSpeed: Double, releaseHeight: Double, releaseDistance: Double,
                lateralOffset: Double = 0, lateralAimError: Double = 0) {
        self.releaseAngle = releaseAngle; self.releaseSpeed = releaseSpeed; self.releaseHeight = releaseHeight
        self.releaseDistance = releaseDistance; self.lateralOffset = lateralOffset; self.lateralAimError = lateralAimError
    }

    public var releasePoint: SIMD3<Double> { SIMD3(-releaseDistance, lateralOffset, releaseHeight - Court.rimHeight) }
    public var apexHeight: Double { releaseHeight + pow(releaseSpeed * sin(releaseAngle), 2) / (2 * Court.g) }
}

public struct CameraPlacement: Sendable {
    /// 0 = perpendicular side view; π/2 = head-on from behind the shooter; −π/2 = from behind the basket.
    public var viewAngle: Double
    public var distance: Double            // m from the look-at target (horizontal)
    public var height: Double              // m above floor
    public var intrinsics: CameraIntrinsics
    /// Where the camera points; nil = middle of the arc.
    public var lookAt: SIMD3<Double>? = nil

    public init(viewAngle: Double, distance: Double, height: Double, intrinsics: CameraIntrinsics, lookAt: SIMD3<Double>? = nil) {
        self.viewAngle = viewAngle; self.distance = distance; self.height = height; self.intrinsics = intrinsics; self.lookAt = lookAt
    }

    public static func iPhone1080p() -> CameraIntrinsics {
        // ~ 1080p slo-mo on a recent iPhone main camera: ≈ 64° horizontal FOV (26 mm equiv. crop).
        // Kept at 64° because Phase 1's gate numbers were produced with it; `iPhone14Pro1080p120`
        // carries the value actually measured on footage.
        CameraIntrinsics(width: 1920, height: 1080, horizontalFOVDegrees: 64)
    }

    /// Measured intrinsics of the 2026-09-13 1080p120 slo-mo clips (iPhone 14 Pro, 1× lens).
    ///
    /// 66.5° ± 2° horizontal FOV, from a vanishing-point calibration of all three clips — the
    /// vertical vanishing point of the light poles and fence posts against the ground-plane
    /// vanishing point of the court lines, which are orthogonal, so f² = −(v₁−c)·(v₂−c). The three
    /// clips gave 66.3°, 67.8° and 65.4°. Cross-checks: the implied lens height (0.9–1.1 m against
    /// a tripod at ~1.2 m) and the shooter's feet on the floor plane reproducing the known station
    /// distances. See docs/PHASE2-PREP.md, "Three-point scale error: root cause (2026-09-14)".
    ///
    /// Do **not** infer fx from an assumed rim distance: that is how the 48° that produced a 9–16 %
    /// gravity deficit on the three-point block was arrived at.
    public static func iPhone14Pro1080p120() -> CameraIntrinsics {
        CameraIntrinsics(width: 1920, height: 1080, horizontalFOVDegrees: 66.5)
    }
}

public struct SimulationOptions: Sendable {
    public var fps: Double = 240
    public var noisePx: Double = 0
    public var dropFraction: Double = 0
    public var seed: UInt64 = 1
    /// Constant-acceleration push before release (the ball's velocity ramps 0 → v over this time).
    public var pushDuration: Double = 0.18
    /// Recording starts this long before release (ball held at the set point before the push).
    public var preReleaseTime: Double = 0.35
    /// Frames after rim contact, on a reflected (bounced) path, to exercise end detection. 0 = track ends at the rim.
    public var postContactDuration: Double = 0.12
    /// Gaussian jitter on frame timestamps, seconds.
    public var timestampJitter: Double = 0
    /// Consecutive frames after release that are dropped (hand/arm occlusion).
    public var occludedFramesAfterRelease: Int = 0
    public var rimBoundaryPoints: Int = 64
    public var rimNoisePx: Double = 0.3
    public var ballDiameter: Double = BallSize.size7.diameter
    public var diameterNoisePx: Double = 0
    public init() {}
}

public enum FramePhase: String, Sendable { case hold, push, flight, contact }

public struct SimulatedFrame: Sendable {
    public var index: Int
    public var t: Double
    public var phase: FramePhase
    public var world: SIMD3<Double>
    public var uvTrue: SIMD2<Double>
    public var uv: SIMD2<Double>
    public var depth: Double
    public var diameterPx: Double
    public var dropped: Bool
    public var outOfFrame: Bool
}

public struct SimulationTruth: Sendable {
    public var releaseTime: Double            // always 0 in this simulator
    public var entryAngle: Double
    public var depthPastFrontRim: Double
    public var rimCrossingOffset: Double
    public var apexHeight: Double
    public var timeOfFlight: Double
    public var planeNormalCamera: SIMD3<Double>
    public var upCamera: SIMD3<Double>
    public var rimCenterCamera: SIMD3<Double>
    public var viewAngle: Double
}

public struct SimulatedShot: Sendable {
    public var parameters: ShotParameters
    public var placement: CameraPlacement
    public var options: SimulationOptions
    public var camera: Camera
    public var frames: [SimulatedFrame]
    public var rimBoundary: [SIMD2<Double>]
    public var truth: SimulationTruth

    /// Detections the pipeline would receive: not dropped, in frame.
    public var samples: [ImageSample] {
        frames.filter { !$0.dropped && !$0.outOfFrame }.map { ImageSample(t: $0.t, uv: $0.uv, diameterPx: $0.diameterPx) }
    }
}

public enum ShotSimulator {
    /// Ball centre in the world frame at time `t` (release at t = 0).
    public static func worldPosition(_ p: ShotParameters, t: Double, options: SimulationOptions) -> (SIMD3<Double>, FramePhase) {
        let th = p.releaseAngle, eps = p.lateralAimError
        let dir = SIMD3(cos(th) * cos(eps), cos(th) * sin(eps), sin(th))
        let v = p.releaseSpeed
        let P0 = p.releasePoint
        if t < 0 {
            let T = options.pushDuration
            if t <= -T { return (P0 - (v * T / 2) * dir, .hold) }
            return (P0 + v * (t + t * t / (2 * T)) * dir, .push)
        }
        let tStar = flightTime(p)
        if t <= tStar {
            var pos = P0 + v * t * dir
            pos.z -= 0.5 * Court.g * t * t
            return (pos, .flight)
        }
        // Crude bounce: reflect vertical velocity with restitution 0.5, keep 60% of horizontal speed.
        var atRim = P0 + v * tStar * dir
        atRim.z -= 0.5 * Court.g * tStar * tStar
        let vzAt = v * sin(th) - Court.g * tStar
        let dt = t - tStar
        let vz2 = -0.5 * vzAt
        var pos = atRim + 0.6 * v * cos(th) * dt * SIMD3(cos(eps), sin(eps), 0)
        pos.z += vz2 * dt - 0.5 * Court.g * dt * dt
        return (pos, .contact)
    }

    /// Descending time at which the ball centre reaches rim height. If it never does, the time of apex ×2.
    public static func flightTime(_ p: ShotParameters) -> Double {
        let vy = p.releaseSpeed * sin(p.releaseAngle)
        let disc = vy * vy - 2 * Court.g * (Court.rimHeight - p.releaseHeight)
        if disc < 0 { return 2 * vy / Court.g }
        return (vy + disc.squareRoot()) / Court.g
    }

    public static func makeCamera(_ p: ShotParameters, placement: CameraPlacement) -> Camera {
        let target = placement.lookAt ?? SIMD3(-p.releaseDistance / 2, 0, (p.releaseHeight + max(p.apexHeight, Court.rimHeight)) / 2 - Court.rimHeight)
        let dirH = SIMD3(-sin(placement.viewAngle), cos(placement.viewAngle), 0)
        var pos = target + placement.distance * dirH
        pos.z = placement.height - Court.rimHeight
        return Camera(intrinsics: placement.intrinsics, pose: .lookAt(from: pos, at: target))
    }

    public static func simulate(_ p: ShotParameters, placement: CameraPlacement, options: SimulationOptions = .init()) -> SimulatedShot {
        var rng = SeededRNG(seed: options.seed)
        let cam = makeCamera(p, placement: placement)
        let tStar = flightTime(p)
        let tEnd = tStar + options.postContactDuration
        var frames: [SimulatedFrame] = []
        var k = 0
        var releaseSeen = 0
        while true {
            var t = -options.preReleaseTime + Double(k) / options.fps
            if t > tEnd { break }
            if options.timestampJitter > 0 { t += rng.gaussian(sd: options.timestampJitter) }
            let (w, phase) = worldPosition(p, t: t, options: options)
            var dropped = rng.uniform() < options.dropFraction
            if phase == .flight { releaseSeen += 1; if releaseSeen <= options.occludedFramesAfterRelease { dropped = true } }
            if let proj = cam.project(world: w) {
                let d = placement.intrinsics.fx * options.ballDiameter / proj.depth
                let noisy = proj.pixel + SIMD2(rng.gaussian(sd: options.noisePx), rng.gaussian(sd: options.noisePx))
                let dn = d + (options.diameterNoisePx > 0 ? rng.gaussian(sd: options.diameterNoisePx) : 0)
                let inFrame = placement.intrinsics.contains(proj.pixel)
                frames.append(SimulatedFrame(index: k, t: t, phase: phase, world: w, uvTrue: proj.pixel, uv: noisy, depth: proj.depth,
                                             diameterPx: dn, dropped: dropped, outOfFrame: !inFrame))
            } else {
                frames.append(SimulatedFrame(index: k, t: t, phase: phase, world: w, uvTrue: SIMD2(.nan, .nan), uv: SIMD2(.nan, .nan),
                                             depth: -1, diameterPx: 0, dropped: true, outOfFrame: true))
            }
            k += 1
        }

        var rim: [SIMD2<Double>] = []
        for i in 0..<options.rimBoundaryPoints {
            let phi = 2 * .pi * Double(i) / Double(options.rimBoundaryPoints)
            let w = SIMD3(Court.rimInnerRadius * cos(phi), Court.rimInnerRadius * sin(phi), 0)
            if let proj = cam.project(world: w) {
                rim.append(proj.pixel + SIMD2(rng.gaussian(sd: options.rimNoisePx), rng.gaussian(sd: options.rimNoisePx)))
            }
        }

        // Truth
        let fwd = Physics.forward(theta: p.releaseAngle, v: p.releaseSpeed, h: p.releaseHeight, L: p.releaseDistance)
        let dH = SIMD3(p.releaseDistance, -p.lateralOffset, 0)
        let nWorld = unit(cross3(SIMD3(0, 0, 1), dH))
        let nCam = cam.pose.rotate(nWorld)
        let upCam = cam.pose.rotate(SIMD3(0, 0, 1))
        let zh = unit(SIMD3<Double>(0, 0, 1) - upCam.z * upCam)
        let truth = SimulationTruth(releaseTime: 0, entryAngle: fwd?.entry ?? .nan, depthPastFrontRim: fwd?.depth ?? .nan,
                                    rimCrossingOffset: (fwd?.depth ?? .nan) - Court.rimInnerRadius, apexHeight: p.apexHeight,
                                    timeOfFlight: tStar, planeNormalCamera: nCam, upCamera: upCam,
                                    rimCenterCamera: cam.pose.toCamera(.zero), viewAngle: acos(min(1, abs(dot3(zh, nCam)))))
        return SimulatedShot(parameters: p, placement: placement, options: options, camera: cam, frames: frames, rimBoundary: rim, truth: truth)
    }
}
