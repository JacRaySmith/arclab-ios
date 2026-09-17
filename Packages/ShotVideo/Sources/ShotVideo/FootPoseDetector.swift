import Foundation
import CoreImage
import CoreML
import CoreVideo
import simd
import ShotGeometry

/// The feet, which Vision cannot see: heel, big toe and little toe per foot, from an RTMPose-m
/// Halpe-26 model converted to Core ML (`Resources/ArcLabFootModel.mlpackage`).
///
/// **Why a whole-person crop and not a foot crop.** RTMPose is a *top-down* model: it was trained on
/// person boxes resized to 256×192, and it locates a foot partly from where the rest of the body is.
/// Handing it a below-knee crop is out of distribution and it answers confidently and wrongly
/// (`docs/research/whole-body-landmarks-2026-09-16.md` §1.5). So the crop here is the person box —
/// the same joint box `BodyTracker` already computes — put through mmpose's own `TopdownAffine`
/// geometry: pad the box by 1.25, fix its aspect ratio to 192:256, then scale it onto 192×256.
///
/// **Decode.** The SimCC head emits two 1-D classifications per keypoint, x over `192 × 2 = 384`
/// bins and y over `256 × 2 = 512`. `argmax ÷ 2` is the coordinate in crop pixels and the max value
/// is the confidence — no heatmap Gaussian, no NMS, one person. Quantisation is therefore 0.5 crop
/// pixels, which at this framing is ~0.9 full-frame pixels and is *not* the accuracy limit; the
/// model's own error on small extremities is.
///
/// **Licence.** The model's code is Apache-2.0 (mmpose) but its training annotations are Halpe /
/// AlphaPose, "academic or non-profit organization noncommercial research use only". This detector
/// is therefore an **internal measurement and labelling engine**, not a shipping component — see
/// `docs/DECISIONS.md` "feet detector".
public final class FootPoseDetector: @unchecked Sendable {

    /// What the model was trained to emit, in order (`meta.dataset_meta.keypoint_id2name` of the
    /// checkpoint). Indices 20–25 are the six points this whole track exists for.
    public static let halpe26: [String] = [
        "nose", "left_eye", "right_eye", "left_ear", "right_ear",
        "left_shoulder", "right_shoulder", "left_elbow", "right_elbow", "left_wrist", "right_wrist",
        "left_hip", "right_hip", "left_knee", "right_knee", "left_ankle", "right_ankle",
        "head", "neck", "hip",
        "left_big_toe", "right_big_toe", "left_small_toe", "right_small_toe", "left_heel", "right_heel"]

    /// Halpe index → the ArcLab 2-D point name, for the six points that go into `BodyFrame.points2D`.
    static let footIndexToName: [Int: String] = [
        20: Body2DPoint.leftBigToe, 21: Body2DPoint.rightBigToe,
        22: Body2DPoint.leftLittleToe, 23: Body2DPoint.rightLittleToe,
        24: Body2DPoint.leftHeel, 25: Body2DPoint.rightHeel]

    /// The model's other 20 keypoints, exported under a `footModel.` prefix when
    /// `Options.footModelCrossCheck` is on, so they can be measured against Vision's own without
    /// ever being mistaken for them.
    static let crossCheckPrefix = "footModel."

    // Geometry the model was trained with. Changing any of these invalidates the conversion.
    public static let inputWidth = 192, inputHeight = 256
    public static let splitRatio = 2.0
    public static let bboxPadding = 1.25

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let model: MLModel
    private var buffer: CVPixelBuffer?
    private let lock = NSLock()

    /// Loads (and, the first time, compiles) the bundled model. Throws rather than degrading silently:
    /// a missing model must not look like a shooter with no feet.
    public init(computeUnits: MLComputeUnits = .all) throws {
        let url = try Self.compiledModelURL()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try MLModel(contentsOf: url, configuration: configuration)
    }

    /// The compiled model: an Xcode build's `.mlmodelc` if present, else the `.mlpackage` SwiftPM
    /// copied, compiled once into the caches directory. Same shape as `ModelBox.compiledModelURL`,
    /// and the resource is named `ArcLabFootModel` so the Swift class Xcode generates from the file
    /// name cannot collide with anything in this package (`ArcLabBallModel` is the other one).
    static func compiledModelURL() throws -> URL {
        if let compiled = Bundle.module.url(forResource: "ArcLabFootModel", withExtension: "mlmodelc") { return compiled }
        guard let raw = Bundle.module.url(forResource: "ArcLabFootModel", withExtension: "mlpackage") else {
            throw FootPoseDetectorError.modelMissing
        }
        let fm = FileManager.default
        let cacheRoot = (fm.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory)
            .appendingPathComponent("ArcLab", isDirectory: true)
        let cached = cacheRoot.appendingPathComponent("ArcLabFootModel.mlmodelc", isDirectory: true)
        let sourceDate = (try? raw.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
        if let cachedDate = try? cached.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           cachedDate >= sourceDate {
            return cached
        }
        let semaphore = DispatchSemaphore(value: 0)
        var result: Swift.Result<URL, any Error>?
        MLModel.compileModel(at: raw) { r in result = r; semaphore.signal() }
        semaphore.wait()
        guard let result else { throw FootPoseDetectorError.compileFailed("no result") }
        let temporary: URL
        switch result {
        case .success(let u): temporary = u
        case .failure(let e): throw FootPoseDetectorError.compileFailed("\(e)")
        }
        try? fm.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try? fm.removeItem(at: cached)
        do { try fm.moveItem(at: temporary, to: cached) } catch { return temporary }
        return cached
    }

    // MARK: - The crop mmpose would have made

    /// mmpose's `TopDownGetBboxCenterScale(padding: 1.25)` + `TopdownAffine`, with rotation zero —
    /// which reduces exactly to: pad the box, fix its aspect ratio to the input's, and scale that
    /// rectangle onto the input. Verified against `cv2.warpAffine` with mmpose's own warp matrix.
    public struct Crop: Sendable, Equatable {
        public var centreU: Double, centreV: Double, width: Double, height: Double
        public var rect: CGRect { CGRect(x: centreU - width / 2, y: centreV - height / 2, width: width, height: height) }
        /// Full-frame pixels per model-crop pixel.
        public var scale: Double { width / Double(FootPoseDetector.inputWidth) }
    }

    public static func crop(minU: Double, minV: Double, maxU: Double, maxV: Double) -> Crop {
        let cu = (minU + maxU) / 2, cv = (minV + maxV) / 2
        var w = (maxU - minU) * bboxPadding, h = (maxV - minV) * bboxPadding
        let aspect = Double(inputWidth) / Double(inputHeight)
        if w > h * aspect { h = w / aspect } else { w = h * aspect }
        return Crop(centreU: cu, centreV: cv, width: w, height: h)
    }

    /// The person box from a frame's 2-D points. Nil when too few points cleared the gate to define
    /// a box — that is a frame with no foot measurement, and it says so rather than guessing one.
    public static func personBox(points2D: [String: BodyPoint2D], minimumConfidence: Double = 0.3) -> Crop? {
        var minU = Double.infinity, minV = Double.infinity, maxU = -Double.infinity, maxV = -Double.infinity
        var n = 0
        for p in points2D.values where p.confidence >= minimumConfidence && !p.name.hasPrefix(crossCheckPrefix) {
            minU = min(minU, p.u); maxU = max(maxU, p.u); minV = min(minV, p.v); maxV = max(maxV, p.v); n += 1
        }
        guard n >= 4, maxU > minU, maxV > minV else { return nil }
        return crop(minU: minU, minV: minV, maxU: maxU, maxV: maxV)
    }

    // MARK: - One frame

    public struct Prediction: Sendable {
        /// Halpe index → (full-frame pixels, confidence). Every one of the 26, gated by the caller.
        public var keypoints: [Int: (uv: SIMD2<Double>, confidence: Double)]
        public var crop: Crop
        public var seconds: Double
    }

    /// Runs the model on the person crop of `frame` and maps every keypoint back to full-frame pixels.
    public func run(_ frame: CVPixelBuffer, imageSize: CGSize, crop: Crop) throws -> Prediction {
        lock.lock(); defer { lock.unlock() }
        let t0 = Date()
        guard let input = render(frame, imageSize: imageSize, crop: crop) else { throw FootPoseDetectorError.renderFailed }
        let out = try model.prediction(from: FootModelInput(image: input))
        guard let sx = out.featureValue(for: "simcc_x")?.multiArrayValue,
              let sy = out.featureValue(for: "simcc_y")?.multiArrayValue else {
            throw FootPoseDetectorError.unexpectedOutput
        }
        let keypoints = Self.decode(simccX: sx, simccY: sy, crop: crop)
        return Prediction(keypoints: keypoints, crop: crop, seconds: Date().timeIntervalSince(t0))
    }

    /// argmax ÷ split ratio in each 1-D classification, then crop pixels → full-frame pixels.
    /// The confidence is `min(max_x, max_y)`: a keypoint is only as well located as its worse axis.
    static func decode(simccX: MLMultiArray, simccY: MLMultiArray, crop: Crop) -> [Int: (uv: SIMD2<Double>, confidence: Double)] {
        let k = halpe26.count
        let wBins = Int(truncating: simccX.shape[simccX.shape.count - 1])
        let hBins = Int(truncating: simccY.shape[simccY.shape.count - 1])
        var result: [Int: (uv: SIMD2<Double>, confidence: Double)] = [:]
        result.reserveCapacity(k)
        let sxPtr = simccX.dataPointer.bindMemory(to: Float32.self, capacity: k * wBins)
        let syPtr = simccY.dataPointer.bindMemory(to: Float32.self, capacity: k * hBins)
        let sx = crop.width / Double(inputWidth), sy = crop.height / Double(inputHeight)
        let u0 = crop.centreU - crop.width / 2, v0 = crop.centreV - crop.height / 2
        for j in 0..<k {
            var bestX = 0, bestY = 0
            var vx = -Float.greatestFiniteMagnitude, vy = -Float.greatestFiniteMagnitude
            let rowX = sxPtr + j * wBins, rowY = syPtr + j * hBins
            for i in 0..<wBins where rowX[i] > vx { vx = rowX[i]; bestX = i }
            for i in 0..<hBins where rowY[i] > vy { vy = rowY[i]; bestY = i }
            let confidence = Double(min(vx, vy))
            let cx = Double(bestX) / splitRatio, cy = Double(bestY) / splitRatio
            result[j] = (SIMD2(u0 + cx * sx, v0 + cy * sy), confidence)
        }
        return result
    }

    /// Renders the crop rectangle straight onto a 192×256 BGRA buffer — crop and resize in one
    /// `CIContext.render`, the same single step `cv2.warpAffine` does in the Python verification.
    private func render(_ source: CVPixelBuffer, imageSize: CGSize, crop: Crop) -> CVPixelBuffer? {
        let w = Self.inputWidth, h = Self.inputHeight
        if buffer == nil {
            var made: CVPixelBuffer?
            let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
            guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &made) == kCVReturnSuccess,
                  let made else { return nil }
            buffer = made
        }
        guard let destination = buffer else { return nil }
        let rect = crop.rect
        // CIImage is y-up from the bottom-left of the extent; the pixel buffer's first row is the top.
        let ciRect = CGRect(x: rect.origin.x, y: imageSize.height - rect.origin.y - rect.height,
                            width: rect.width, height: rect.height)
        let s = Double(w) / rect.width
        // `clampedToExtent` so a crop that runs off the frame edge is filled by edge replication
        // rather than by transparent black, which the model would read as a hard shadow.
        let image = CIImage(cvPixelBuffer: source).clampedToExtent()
            .cropped(to: ciRect)
            .transformed(by: CGAffineTransform(translationX: -ciRect.origin.x, y: -ciRect.origin.y))
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
        context.render(image, to: destination, bounds: CGRect(x: 0, y: 0, width: Double(w), height: Double(h)),
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        return destination
    }
}

/// The model's single image input, by name. A hand-written `MLFeatureProvider` rather than the Xcode
/// generated class, because SwiftPM never generates one.
final class FootModelInput: NSObject, MLFeatureProvider {
    let image: CVPixelBuffer
    init(image: CVPixelBuffer) { self.image = image }
    var featureNames: Set<String> { ["image"] }
    func featureValue(for featureName: String) -> MLFeatureValue? {
        featureName == "image" ? MLFeatureValue(pixelBuffer: image) : nil
    }
}

public enum FootPoseDetectorError: Error, CustomStringConvertible {
    case modelMissing, renderFailed, unexpectedOutput
    case compileFailed(String)
    public var description: String {
        switch self {
        case .modelMissing: return "ArcLabFootModel.mlpackage is not in the ShotVideo resource bundle"
        case .renderFailed: return "the person crop could not be rendered onto the model's 192×256 input"
        case .unexpectedOutput: return "the foot model did not return simcc_x and simcc_y"
        case .compileFailed(let s): return "the Core ML compiler could not compile ArcLabFootModel.mlpackage: \(s)"
        }
    }
}
