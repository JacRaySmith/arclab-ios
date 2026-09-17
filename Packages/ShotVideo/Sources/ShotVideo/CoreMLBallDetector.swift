import Foundation
import CoreML
import CoreVideo
import CoreGraphics

/// The trained Create ML ball detector, run on 512-pixel square tiles of the full-resolution frame.
///
/// **Why the model is driven directly and not through Vision.** `docs/reference/sdk-and-licensing-research-2026-09-12.md`
/// §1(d) records `CoreMLRequest` / `CoreMLModelContainer` / `RecognizedObjectObservation` as the intended path and flags
/// the result type as unverified. Measured on macOS 26.6 with this model: **both** Vision paths refuse it.
/// `CoreMLModelContainer(model:)` builds and reports `inputImageFeatureName == "image"`, but `perform` fails with
/// `VisionError.invalidModel("The inputImageFeatureName does not point to a MLFeatureTypeImage input.")`, and the legacy
/// `VNCoreMLRequest` fails with the same underlying error (Vision code 15) — with and without a `featureProvider` for the
/// model's two optional `Double` inputs, with `inputImageFeatureName` assigned explicitly, on a plain 512×512 buffer with
/// no region of interest, and on the full frame with one. The model is a three-stage pipeline
/// (`VisionFeaturePrint.Object` → neural network → non-maximum suppression) whose image input carries a *flexible* size
/// (299…×299…); Vision appears not to accept that combination. `MLModel.prediction(from:)` on the same buffer works, so
/// this type crops the tile itself and calls Core ML directly. Nothing is lost: the pipeline already ends in an NMS layer,
/// which is the only thing `RecognizedObjectObservation` would have added.
///
/// **Scale.** The model was trained on 512×512 tiles cut from 1080p frames, with the ball 26–140 px across, so a tile is
/// cut at **native resolution** — no downscaling of the source — and the 512-px window is the field of view the model
/// expects. The model's own input is resized internally; on the held-out tiles the input size makes no measurable
/// difference (299 → 512 all give 100 % recall and ~10 px mean centre error), the *source window* is what matters.
///
/// Coordinates in and out are **top-left pixel coordinates of the full-resolution frame**, the same convention as
/// `BallDetection.u/v` and `JointSample.u/v`.
public enum CoreMLBallDetector {
    /// The side of the square tile handed to the model, in full-resolution source pixels (the training tile size).
    public static let tilePixels = 512
    /// Stride between tiles when the whole frame has to be searched; 512 − 448 = 64 px of overlap.
    public static let tileStride = 448
    /// From this many tiles on one frame, the model is given them as one batch rather than one at a time.
    /// Two, so every multi-tile frame (a widened region, a whole-frame sweep) takes the batch path and the
    /// single-tile steady state — which is most frames — keeps the cheaper single-prediction path.
    /// `ARCLAB_NO_BATCH=1` forces the one-at-a-time path, so the two can be timed in one binary.
    static let batchThreshold = ProcessInfo.processInfo.environment["ARCLAB_NO_BATCH"] == "1" ? Int.max : 2

    /// Loads (and, the first time, compiles) the bundled model. Idempotent. Call it once before a frame loop so the
    /// compile does not land inside a measured inference time; `detect` loads on demand if this was never called.
    public static func prepare() async throws {
        if ModelBox.shared.isLoaded { return }
        _ = try ModelBox.shared.model()
    }

    /// True once the model is in memory.
    public static var isLoaded: Bool { ModelBox.shared.isLoaded }

    /// Per-frame ball candidates.
    ///
    /// - Parameters:
    ///   - pixelBuffer: a full-resolution decoded frame (4:2:0 bi-planar or a packed 32-bit format).
    ///   - roi: the region of the frame to search, in top-left pixel coordinates. It is covered by 512-px tiles; a
    ///     region smaller than a tile costs exactly one inference. `nil` searches the whole frame on a grid of stride
    ///     `tileStride` (15 tiles at 1080p), which is what the caller wants only when it has no prediction.
    ///   - minConfidence: boxes below this are dropped. Also passed to the model's own `confidenceThreshold` input.
    /// - Returns: one entry per surviving box, in full-frame pixels, strongest first. Never extrapolates: no box, no entry.
    public static func detect(pixelBuffer: CVPixelBuffer, roi: CGRect?, minConfidence: Float)
        throws -> [(u: Double, v: Double, diameterPx: Double, confidence: Float)]
    {
        try detect(tiles: try cutTiles(pixelBuffer: pixelBuffer, roi: roi), minConfidence: minConfidence)
    }

    /// One 512-px tile, cut out of a frame and ready for the model, with the frame coordinates it came from.
    public struct Tile: @unchecked Sendable {
        public let x0: Int, y0: Int, side: Int
        public let buffer: CVPixelBuffer
    }

    /// Cut the tiles `detect` would run, **without** running them. A tile is a `memcpy` per row, so a decode
    /// loop can cut them while the frame's pixel buffer is still in hand (it may not escape its closure) and
    /// then hand the tiles to the model from another thread, overlapping the inference with the next frame's
    /// decode. The tiles come out in the order `detect` would run them, so the result is the same.
    public static func cutTiles(pixelBuffer: CVPixelBuffer, roi: CGRect?) throws -> [Tile] {
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        let tile = min(tilePixels, min(width, height))
        guard tile >= 2 else { return [] }
        let xs: [Int], ys: [Int]
        if let roi {
            xs = origins(from: Int(roi.minX.rounded(.down)), to: Int(roi.maxX.rounded(.up)), span: tile, limit: width)
            ys = origins(from: Int(roi.minY.rounded(.down)), to: Int(roi.maxY.rounded(.up)), span: tile, limit: height)
        } else {
            xs = origins(from: 0, to: width, span: tile, limit: width)
            ys = origins(from: 0, to: height, span: tile, limit: height)
        }
        var out: [Tile] = []
        out.reserveCapacity(xs.count * ys.count)
        for y0 in ys {
            for x0 in xs {
                guard let cut = ModelBox.shared.cut(pixelBuffer, x0: x0, y0: y0, tile: tile) else {
                    throw CoreMLBallDetectorError.cropFailed
                }
                // The **requested** origin, not the one `crop` clamped and rounded to an even pixel. That is
                // what this detector has always mapped its boxes back with; the two differ by at most one
                // pixel, and changing it would move every box a little, which is a measurement change, not an
                // optimisation. (Worth fixing on purpose one day: see PHASE2-PREP, "Pipeline optimisation".)
                _ = cut.x0; _ = cut.y0
                out.append(Tile(x0: x0, y0: y0, side: tile, buffer: cut.buffer))
            }
        }
        return out
    }

    /// Run the model over already-cut tiles. Identical to `detect(pixelBuffer:roi:)` on the tiles that call
    /// would have cut, in the same order.
    public static func detect(tiles: [Tile], minConfidence: Float)
        throws -> [(u: Double, v: Double, diameterPx: Double, confidence: Float)]
    {
        guard !tiles.isEmpty else { return [] }
        let model = try ModelBox.shared.model()
        var found: [(u: Double, v: Double, diameterPx: Double, confidence: Float)] = []
        // A whole-frame sweep is 15 tiles with nothing between them; handed over as a batch, Core ML schedules
        // them as one piece of work instead of fifteen round trips. The model is per-image (its last stage is
        // non-maximum suppression *within* an image), so the boxes are the same either way.
        let perTile: [[(x: Double, y: Double, w: Double, h: Double, confidence: Float)]] =
            tiles.count >= batchThreshold
                ? try ModelBox.shared.predictBatch(model, tiles.map(\.buffer), minConfidence: minConfidence)
                : try tiles.map { try ModelBox.shared.predict(model, $0.buffer, minConfidence: minConfidence) }
        for (t, boxes) in zip(tiles, perTile) {
            let side = Double(t.side)
            for b in boxes {
                // model box: centre and size normalized to the tile
                found.append((u: Double(t.x0) + b.x * side,
                              v: Double(t.y0) + b.y * side,
                              diameterPx: 0.5 * (b.w + b.h) * side,
                              confidence: b.confidence))
            }
        }
        return suppress(found)
    }

    /// Tile origins covering `[a, b]` with windows of `span`, clamped inside `[0, limit − span]`.
    static func origins(from a: Int, to b: Int, span: Int, limit: Int) -> [Int] {
        let highest = max(0, limit - span)
        var x = min(max(0, a), highest)
        let last = min(max(0, b - span), highest)
        var out = [x]
        while x < last {
            x = min(x + tileStride, last)
            out.append(x)
        }
        return out
    }

    /// Overlapping tiles see the same ball twice. Keep the strongest box and drop anything whose centre is within
    /// half a diameter of one already kept.
    static func suppress(_ boxes: [(u: Double, v: Double, diameterPx: Double, confidence: Float)])
        -> [(u: Double, v: Double, diameterPx: Double, confidence: Float)]
    {
        var kept: [(u: Double, v: Double, diameterPx: Double, confidence: Float)] = []
        for b in boxes.sorted(by: { $0.confidence > $1.confidence }) {
            let clash = kept.contains { k in
                let d = ((k.u - b.u) * (k.u - b.u) + (k.v - b.v) * (k.v - b.v)).squareRoot()
                return d < 0.5 * max(k.diameterPx, b.diameterPx)
            }
            if !clash { kept.append(b) }
        }
        return kept
    }
}

// MARK: - Model loading and inference

/// Holds the compiled model and serializes prediction. `MLModel` is not documented as thread-safe for concurrent
/// `prediction(from:)`, and the detector is called from one decode loop anyway.
final class ModelBox: @unchecked Sendable {
    static let shared = ModelBox()

    private let lock = NSLock()
    private var loaded: MLModel?
    private var pool: CVPixelBufferPool?
    private var poolFormat: OSType = 0
    private var poolSide = 0

    var isLoaded: Bool { lock.lock(); defer { lock.unlock() }; return loaded != nil }

    func model() throws -> MLModel {
        lock.lock(); defer { lock.unlock() }
        if let loaded { return loaded }
        let url = try Self.compiledModelURL()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let m = try MLModel(contentsOf: url, configuration: configuration)
        loaded = m
        return m
    }

    /// The `.mlmodelc` to load: the one an Xcode build compiled into the bundle if it is there, otherwise the bundled
    /// `.mlmodel` compiled once into the caches directory (SwiftPM copies resources verbatim — it does not run the
    /// Core ML compiler, verified on this toolchain: the build log says "Copying ArcLabBallModel.mlmodel"). The file is
    /// named `ArcLabBallModel` rather than `BallDetector` because an Xcode build *does* compile it and generates a Swift
    /// class from the file name, which would collide with this package's own `BallDetector` type.
    static func compiledModelURL() throws -> URL {
        if let compiled = Bundle.module.url(forResource: "ArcLabBallModel", withExtension: "mlmodelc") { return compiled }
        guard let raw = Bundle.module.url(forResource: "ArcLabBallModel", withExtension: "mlmodel") else {
            throw CoreMLBallDetectorError.modelMissing
        }
        let fm = FileManager.default
        let cacheRoot = (fm.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory)
            .appendingPathComponent("ArcLab", isDirectory: true)
        let cached = cacheRoot.appendingPathComponent("ArcLabBallModel.mlmodelc", isDirectory: true)
        // Reuse the cached compile only when it is newer than the model it came from.
        let sourceDate = (try? raw.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
        if let cachedDate = try? cached.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           cachedDate >= sourceDate {
            return cached
        }
        // Only the async / completion-handler `compileModel` exists in Swift; the completion runs on Core ML's own
        // queue, so waiting here cannot deadlock. `prepare()` keeps this off the hot path in practice.
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<URL, any Error>?
        MLModel.compileModel(at: raw) { r in result = r; semaphore.signal() }
        semaphore.wait()
        guard let result else { throw CoreMLBallDetectorError.compileFailed("no result") }
        let temporary: URL
        switch result {
        case .success(let u): temporary = u
        case .failure(let e): throw CoreMLBallDetectorError.compileFailed("\(e)")
        }
        try? fm.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try? fm.removeItem(at: cached)
        do { try fm.moveItem(at: temporary, to: cached) } catch { return temporary }
        return cached
    }

    /// Cut one tile out of a frame, with the clamped, even origin it actually landed on. Cheap: a `memcpy` a row.
    func cut(_ source: CVPixelBuffer, x0: Int, y0: Int, tile: Int) -> (x0: Int, y0: Int, buffer: CVPixelBuffer)? {
        lock.lock(); defer { lock.unlock() }
        let format = CVPixelBufferGetPixelFormatType(source)
        if pool == nil || poolFormat != format || poolSide != tile {
            pool = (try? Self.makePool(format: format, side: tile)) ?? pool
            poolFormat = format; poolSide = tile
        }
        guard let pool, let cropped = Self.crop(source, x0: x0, y0: y0, side: tile, pool: pool) else { return nil }
        // The same clamping `crop` applies, so the caller maps the boxes back to the tile it really got.
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        var cx = max(0, min(width - tile, x0)), cy = max(0, min(height - tile, y0))
        cx -= cx % 2; cy -= cy % 2
        return (cx, cy, cropped)
    }

    /// One already-cut tile through the model. Returns boxes normalized to the tile (centre x, y and size w, h in 0…1).
    func predict(_ model: MLModel, _ cropped: CVPixelBuffer, minConfidence: Float)
        throws -> [(x: Double, y: Double, w: Double, h: Double, confidence: Float)]
    {
        lock.lock(); defer { lock.unlock() }
        let out = try model.prediction(from: TileInput(image: cropped, minConfidence: Double(minConfidence)))
        return Self.boxes(from: out, minConfidence: minConfidence)
    }

    /// The model's two output arrays, read the same way whether one tile or a batch produced them.
    static func boxes(from out: MLFeatureProvider, minConfidence: Float)
        -> [(x: Double, y: Double, w: Double, h: Double, confidence: Float)]
    {
        guard let confidence = out.featureValue(for: "confidence")?.multiArrayValue,
              let coordinates = out.featureValue(for: "coordinates")?.multiArrayValue else { return [] }
        let n = confidence.shape.first?.intValue ?? 0
        guard n > 0, coordinates.shape.first?.intValue == n else { return [] }
        var boxes: [(x: Double, y: Double, w: Double, h: Double, confidence: Float)] = []
        boxes.reserveCapacity(n)
        for i in 0..<n {
            let c = Float(confidence[[i, 0] as [NSNumber]].doubleValue)
            guard c >= minConfidence else { continue }
            boxes.append((x: coordinates[[i, 0] as [NSNumber]].doubleValue,
                          y: coordinates[[i, 1] as [NSNumber]].doubleValue,
                          w: coordinates[[i, 2] as [NSNumber]].doubleValue,
                          h: coordinates[[i, 3] as [NSNumber]].doubleValue,
                          confidence: c))
        }
        return boxes
    }

    /// Several already-cut tiles through the model in one batch. Same boxes, same order, one scheduling round
    /// trip instead of one per tile.
    func predictBatch(_ model: MLModel, _ buffers: [CVPixelBuffer], minConfidence: Float)
        throws -> [[(x: Double, y: Double, w: Double, h: Double, confidence: Float)]]
    {
        lock.lock(); defer { lock.unlock() }
        let batch = MLArrayBatchProvider(array: buffers.map { TileInput(image: $0, minConfidence: Double(minConfidence)) })
        let out = try model.predictions(fromBatch: batch)
        var result: [[(x: Double, y: Double, w: Double, h: Double, confidence: Float)]] = []
        result.reserveCapacity(out.count)
        for i in 0..<out.count { result.append(Self.boxes(from: out.features(at: i), minConfidence: minConfidence)) }
        return result
    }

    static func makePool(format: OSType, side: Int) throws -> CVPixelBufferPool {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: side,
            kCVPixelBufferHeightKey as String: side,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else { throw CoreMLBallDetectorError.cropFailed }
        return pool
    }

    /// A `side`×`side` copy of `source` whose top-left corner is (x0, y0), at native resolution. The origin is forced
    /// even so 4:2:0 chroma lines up, and clamped so the tile stays inside the frame.
    static func crop(_ source: CVPixelBuffer, x0 xIn: Int, y0 yIn: Int, side: Int, pool: CVPixelBufferPool) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        var x0 = max(0, min(width - side, xIn)), y0 = max(0, min(height - side, yIn))
        x0 -= x0 % 2; y0 -= y0 % 2
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let destination = out else { return nil }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        if CVPixelBufferIsPlanar(source) {
            for plane in 0..<CVPixelBufferGetPlaneCount(source) {
                let planeWidth = CVPixelBufferGetWidthOfPlane(source, plane)
                let planeHeight = CVPixelBufferGetHeightOfPlane(source, plane)
                let shrink = max(1, width / max(1, planeWidth))                 // 1 for luma, 2 for 4:2:0 chroma
                let bytesPerSample = CVPixelBufferGetBytesPerRowOfPlane(source, plane) / max(1, planeWidth)
                let sourceStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                let destinationStride = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
                guard let sourceBase = CVPixelBufferGetBaseAddressOfPlane(source, plane)?.assumingMemoryBound(to: UInt8.self),
                      let destinationBase = CVPixelBufferGetBaseAddressOfPlane(destination, plane)?.assumingMemoryBound(to: UInt8.self)
                else { return nil }
                let rows = side / shrink, bytes = (side / shrink) * bytesPerSample
                for row in 0..<rows {
                    let sourceRow = min(planeHeight - 1, y0 / shrink + row)
                    memcpy(destinationBase + row * destinationStride,
                           sourceBase + sourceRow * sourceStride + (x0 / shrink) * bytesPerSample, bytes)
                }
            }
        } else {
            let bytesPerSample = CVPixelBufferGetBytesPerRow(source) / max(1, width)
            let sourceStride = CVPixelBufferGetBytesPerRow(source)
            let destinationStride = CVPixelBufferGetBytesPerRow(destination)
            guard let sourceBase = CVPixelBufferGetBaseAddress(source)?.assumingMemoryBound(to: UInt8.self),
                  let destinationBase = CVPixelBufferGetBaseAddress(destination)?.assumingMemoryBound(to: UInt8.self)
            else { return nil }
            for row in 0..<side {
                memcpy(destinationBase + row * destinationStride,
                       sourceBase + (y0 + row) * sourceStride + x0 * bytesPerSample, side * bytesPerSample)
            }
        }
        return destination
    }
}

/// The model's three inputs: the tile, and the two optional `Double` knobs on its non-maximum-suppression stage.
final class TileInput: NSObject, MLFeatureProvider {
    let image: CVPixelBuffer
    let minConfidence: Double
    init(image: CVPixelBuffer, minConfidence: Double) { self.image = image; self.minConfidence = minConfidence }
    var featureNames: Set<String> { ["image", "iouThreshold", "confidenceThreshold"] }
    func featureValue(for featureName: String) -> MLFeatureValue? {
        switch featureName {
        case "image": return MLFeatureValue(pixelBuffer: image)
        case "iouThreshold": return MLFeatureValue(double: 0.45)
        case "confidenceThreshold": return MLFeatureValue(double: minConfidence)
        default: return nil
        }
    }
}

public enum CoreMLBallDetectorError: Error, CustomStringConvertible {
    case modelMissing
    case compileFailed(String)
    case cropFailed
    public var description: String {
        switch self {
        case .modelMissing: return "ArcLabBallModel.mlmodel is not in the ShotVideo resource bundle"
        case .compileFailed(let s): return "the Core ML compiler could not compile ArcLabBallModel.mlmodel: \(s)"
        case .cropFailed: return "could not cut a tile out of the frame"
        }
    }
}
