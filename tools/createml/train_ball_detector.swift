// Trains a Create ML object detector ("ball") from the auto-labelled tiles exported by tools/pytrack/export_labels.py.
// Usage: swiftc -O -framework CreateML -o /tmp/train_ball tools/createml/train_ball_detector.swift
//        /tmp/train_ball <merged_labels_dir> --out ~/Desktop/BallDetector.mlmodel [--iterations 1500]
// <merged_labels_dir> holds train/ and test/ subdirectories, each with tiles and an annotations.json (Create ML JSON: image, annotations[label, coordinates{x,y,width,height}],
// box centre in pixels, origin top-left). Merge several export dirs into one before calling (see docs/PHASE2-PREP.md).
// Requires Xcode (Create ML framework, macOS). The output model is the developer's own (see docs/DECISIONS.md §9.4).
import Foundation
import CreateML

setvbuf(stdout, nil, _IOLBF, 0)
var args = Array(CommandLine.arguments.dropFirst())
func flag(_ n: String) -> String? { guard let i = args.firstIndex(of: n), i + 1 < args.count else { return nil }; let v = args[i + 1]; args.removeSubrange(i...i + 1); return v }
let out = flag("--out") ?? NSString(string: "~/Desktop/BallDetector.mlmodel").expandingTildeInPath
let iterations = Int(flag("--iterations") ?? "1500") ?? 1500
guard args.count == 1 else { print("usage: train_ball <merged_labels_dir> --out model.mlmodel [--iterations N]"); exit(2) }
let dir = URL(fileURLWithPath: args[0])

func stamp(_ s: String) { print("[\(ISO8601DateFormatter().string(from: Date()))] \(s)") }
func describe(_ m: MLObjectDetectorMetrics, _ name: String) {
    if let e = m.error { print("\(name): unavailable (\(e))"); return }
    print("\(name): mAP@IoU50=\(m.meanAveragePrecision.IoU50)  mAP@variedIoU=\(m.meanAveragePrecision.variedIoU)")
    for (label, ap) in m.averagePrecision.IoU50.sorted(by: { $0.key < $1.key }) {
        print("  \(label): AP@IoU50=\(ap)  AP@variedIoU=\(m.averagePrecision.variedIoU[label] ?? .nan)")
    }
}

stamp("loading \(dir.path)")
// Split on disk beforehand (train/ and test/, each with its own annotations.json) so both training and the held-out
// evaluation use the non-deprecated directory data source.
let trainSource = MLObjectDetector.DataSource.directoryWithImagesAndJsonAnnotation(at: dir.appendingPathComponent("train"))
let testSource = MLObjectDetector.DataSource.directoryWithImagesAndJsonAnnotation(at: dir.appendingPathComponent("test"))
let nTrain = try trainSource.gatherAnnotatedFileNames().rows.count
let nTest = try testSource.gatherAnnotatedFileNames().rows.count
stamp("train \(nTrain) / held-out \(nTest) tiles")

var params = MLObjectDetector.ModelParameters(validation: .split(strategy: .automatic), maxIterations: iterations)
params.algorithm = .transferLearning(.objectPrint(revision: 1))
stamp("training: \(params)")
let detector = try MLObjectDetector(trainingData: trainSource, parameters: params,
                                    annotationType: .boundingBox(units: .pixel, origin: .topLeft, anchor: .center))
stamp("training finished")
describe(detector.trainingMetrics, "training metrics")
describe(detector.validationMetrics, "validation metrics")
let eval = detector.evaluation(on: testSource)
describe(eval, "held-out evaluation (\(nTest) tiles)")
try detector.write(to: URL(fileURLWithPath: out), metadata: MLModelMetadata(author: "ArcLab", shortDescription: "Basketball detector trained on auto-labelled tiles (objectPrint transfer learning)", version: "0.1"))
stamp("wrote \(out)")
