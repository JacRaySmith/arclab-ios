import Foundation
@preconcurrency import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

public enum FrameExport {
    /// Writes the decoded frame nearest `time` (seconds) as a PNG. Returns the PTS actually written.
    public static func writePNG(url: URL, time: Double, to output: URL) async throws -> Double {
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
        guard let best else { throw VideoReaderError.noVideoTrack }
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(best.image, from: best.image.extent) else { throw VideoReaderError.cannotStartReading("CGImage") }
        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw VideoReaderError.cannotStartReading("PNG destination")
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { throw VideoReaderError.cannotStartReading("PNG write") }
        return best.pts
    }
}
