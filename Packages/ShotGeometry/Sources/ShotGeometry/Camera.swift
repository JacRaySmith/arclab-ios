import Foundation

/// Pinhole intrinsics in pixels. Image frame: origin top-left, u right, v **down**.
public struct CameraIntrinsics: Sendable, Equatable {
    public var fx: Double, fy: Double, cx: Double, cy: Double
    public var width: Int, height: Int

    public init(fx: Double, fy: Double, cx: Double, cy: Double, width: Int, height: Int) {
        self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy; self.width = width; self.height = height
    }

    /// Square pixels, principal point at the image centre, from a horizontal field of view.
    public init(width: Int, height: Int, horizontalFOVDegrees: Double) {
        let f = Double(width) / 2 / tan(Angle.radians(horizontalFOVDegrees) / 2)
        self.init(fx: f, fy: f, cx: Double(width) / 2, cy: Double(height) / 2, width: width, height: height)
    }

    /// Pixel → normalised image coordinates (x/z, y/z).
    @inlinable public func normalize(_ px: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2((px.x - cx) / fx, (px.y - cy) / fy)
    }

    @inlinable public func pixel(fromNormalized n: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2(fx * n.x + cx, fy * n.y + cy)
    }

    /// Unit ray in the camera frame through a pixel.
    public func ray(_ px: SIMD2<Double>) -> SIMD3<Double> {
        let n = normalize(px)
        return unit(SIMD3(n.x, n.y, 1))
    }

    public var matrix: [[Double]] { [[fx, 0, cx], [0, fy, cy], [0, 0, 1]] }

    public func contains(_ px: SIMD2<Double>) -> Bool {
        px.x >= 0 && px.y >= 0 && px.x < Double(width) && px.y < Double(height)
    }
}

/// Rigid transform world → camera: `p_cam = R · p_world + t`.
/// Camera frame: x right, y down, z forward (OpenCV convention).
public struct CameraPose: Sendable, Equatable {
    public var r0: SIMD3<Double>, r1: SIMD3<Double>, r2: SIMD3<Double>   // rows of R
    public var t: SIMD3<Double>

    public init(rows r0: SIMD3<Double>, _ r1: SIMD3<Double>, _ r2: SIMD3<Double>, t: SIMD3<Double>) {
        self.r0 = r0; self.r1 = r1; self.r2 = r2; self.t = t
    }

    @inlinable public func rotate(_ p: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(dot3(r0, p), dot3(r1, p), dot3(r2, p))
    }
    @inlinable public func rotateBack(_ p: SIMD3<Double>) -> SIMD3<Double> {
        r0 * p.x + r1 * p.y + r2 * p.z
    }
    @inlinable public func toCamera(_ pWorld: SIMD3<Double>) -> SIMD3<Double> { rotate(pWorld) + t }
    @inlinable public func toWorld(_ pCam: SIMD3<Double>) -> SIMD3<Double> { rotateBack(pCam - t) }

    /// Camera centre in world coordinates.
    public var position: SIMD3<Double> { rotateBack(-t) }

    /// Camera at `from` looking at `at`, with zero roll relative to `worldUp`.
    public static func lookAt(from: SIMD3<Double>, at: SIMD3<Double>, worldUp: SIMD3<Double> = SIMD3(0, 0, 1)) -> CameraPose {
        let forward = unit(at - from)
        let right = unit(cross3(forward, worldUp))
        let down = cross3(forward, right)
        let pose = CameraPose(rows: right, down, forward, t: .zero)
        return CameraPose(rows: right, down, forward, t: -pose.rotate(from))
    }
}

public struct Camera: Sendable, Equatable {
    public var intrinsics: CameraIntrinsics
    public var pose: CameraPose

    public init(intrinsics: CameraIntrinsics, pose: CameraPose) {
        self.intrinsics = intrinsics; self.pose = pose
    }

    /// Project a camera-frame point. Nil if behind the camera.
    public func project(camera p: SIMD3<Double>) -> SIMD2<Double>? {
        guard p.z > 1e-9 else { return nil }
        return intrinsics.pixel(fromNormalized: SIMD2(p.x / p.z, p.y / p.z))
    }

    public func project(world p: SIMD3<Double>) -> (pixel: SIMD2<Double>, depth: Double)? {
        let c = pose.toCamera(p)
        guard let px = project(camera: c) else { return nil }
        return (px, c.z)
    }
}
