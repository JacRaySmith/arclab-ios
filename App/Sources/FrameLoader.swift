import AVFoundation
import CoreImage
import Foundation
import ShotVideo
import UIKit

/// One decoded frame, ready to draw. `UIImage` is immutable here and never mutated after creation,
/// so the box can cross actor boundaries; the PTS is the *file* time of the frame actually decoded
/// (the nearest frame at or after the requested time), never the time that was asked for.
struct FrameImage: @unchecked Sendable {
    let image: UIImage
    let pts: Double
    let pixelSize: CGSize
}

enum FrameLoadError: Error, CustomStringConvertible {
    case noFrame(Double)
    case cannotRender
    var description: String {
        switch self {
        case .noFrame(let t): return String(format: "no frame decoded near %.3f s", t)
        case .cannotRender: return "the decoded frame could not be turned into an image"
        }
    }
}

/// Decodes a single frame into a `UIImage`, in the *decoded* orientation — the same pixel
/// coordinates Vision reports and `CameraIntrinsics` expects — so a tap on the picture and a
/// detection in the analyzer mean the same (u, v). Mirrors `FrameExport.writePNG` without the disk.
enum FrameLoader {
    static func frame(url: URL, time: Double) async throws -> FrameImage {
        let reader = VideoReader(url: url)
        let start = CMTime(seconds: max(0, time - 0.05), preferredTimescale: 600)
        let range = CMTimeRange(start: start, end: CMTime(seconds: time + 0.5, preferredTimescale: 600))
        var best: (pts: Double, image: CIImage)? = nil
        try await reader.forEachFrame(timeRange: range) { frame in
            guard let pb = frame.pixelBuffer else { return true }
            if best == nil || abs(frame.pts - time) < abs(best!.pts - time) {
                best = (frame.pts, CIImage(cvPixelBuffer: pb))
            }
            return frame.pts < time
        }
        guard let best else { throw FrameLoadError.noFrame(time) }
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(best.image, from: best.image.extent) else { throw FrameLoadError.cannotRender }
        let image = UIImage(cgImage: cg)
        return FrameImage(image: image, pts: best.pts, pixelSize: CGSize(width: cg.width, height: cg.height))
    }
}
