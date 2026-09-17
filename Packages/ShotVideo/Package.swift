// swift-tools-version: 6.0
import PackageDescription

// ShotVideo: the AVFoundation + Vision layer. Reads clips at their true per-frame timestamps,
// runs Vision's built-in trajectory detector (the Phase 2 zero-model baseline), exports frames.
// Runs on macOS 26 and iOS 26 so the same code drives the desktop probe and the app.
// ShotGeometry stays pure; this package converts Vision output into ShotGeometry.ImageSample.
let package = Package(
    name: "ShotVideo",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "ShotVideo", targets: ["ShotVideo"]),
    ],
    dependencies: [
        .package(path: "../ShotGeometry"),
    ],
    targets: [
        // The trained Core ML ball detector ships as a package resource. SwiftPM does not run the
        // Core ML compiler, so the raw .mlmodel is copied and CoreMLBallDetector compiles it once at
        // first use (Xcode app builds compile it to .mlmodelc themselves; the loader prefers that).
        // The RTMPose Halpe-26 foot model is shipped *compiled* (Resources/ArcLabFootModel.mlmodelc,
        // made with `xcrun coremlc compile Models/ArcLabFootModel.mlpackage`): an Xcode app build of
        // this package compiles an .mlpackage to the products root and never copies it into the
        // resource bundle, so the 1.3 phone build had no foot model at all. A compiled model is a
        // plain folder that both SwiftPM and Xcode copy as-is. The editable source stays in Models/.
        // (Older note, kept for the record: as an .mlpackage it had to be `.copy`d, not
        // `.process`ed: `.process` descends into the package and asks coremlc to compile the inner
        // model.mlmodel, which the SwiftPM build sandbox denies read access to its weight.bin.
        // FootPoseDetector compiles the copied .mlpackage once at first use, exactly as the ball model.
        .target(name: "ShotVideo", dependencies: ["ShotGeometry"],
                resources: [.process("Resources/ArcLabBallModel.mlmodel"),
                            .copy("Resources/ArcLabFootModel.mlmodelc")]),
        // Desktop CLI: probe metadata, run trajectory detection, export frames.
        .executableTarget(name: "TrajectoryProbe", dependencies: ["ShotVideo", "ShotGeometry"]),
    ]
)
