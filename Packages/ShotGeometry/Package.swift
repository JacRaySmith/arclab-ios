// swift-tools-version: 6.0
import PackageDescription

// ShotGeometry: the pure geometry + statistics layer of the app.
// Depends only on Foundation and simd. No Vision, no AVFoundation, no UIKit.
// Everything here must be testable on a Mac with no device attached.
let package = Package(
    name: "ShotGeometry",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ShotGeometry", targets: ["ShotGeometry"]),
    ],
    targets: [
        .target(name: "ShotGeometry"),
        // Phase 1 gate harness: prints the recovery table for the brief's gate scenarios.
        .executableTarget(name: "GeometryHarness", dependencies: ["ShotGeometry"]),
        // Full assertion suite as an executable (runs without XCTest, e.g. Command Line Tools only).
        .executableTarget(name: "GeometryChecks", dependencies: ["ShotGeometry"]),
        .executableTarget(name: "GeometryDebug", dependencies: ["ShotGeometry"]),
        // Re-runs the skeleton fit on exported BodyShot files: an option sweep over real shots
        // without decoding video (the fit's inputs are all in the export).
        .executableTarget(name: "BodyRefit", dependencies: ["ShotGeometry"]),
        // Runs FootworkMetrics over exported BodyShot files and prints the distributions (Track C).
        .executableTarget(name: "FootworkProbe", dependencies: ["ShotGeometry"]),
        // Hand plates (1.3): coverage at the release instant and what the plates measure, over
        // exported BodyShot files. Its own target for the same reason FootworkProbe is.
        .executableTarget(name: "HandProbe", dependencies: ["ShotGeometry"]),
        // Track D (1.3): the evaluation harness. `FormEvalKit` holds the statistics and the
        // per-shot measurements so they can be unit-tested; `FormEval` is the CLI over a directory
        // of exported BodyShot files. Foundation + simd only, like everything else here.
        .target(name: "FormEvalKit", dependencies: ["ShotGeometry"]),
        .executableTarget(name: "FormEval", dependencies: ["ShotGeometry", "FormEvalKit"]),
        // The measurement pipeline (docs/PIPELINE.md): replays cached shot windows (written by
        // `TrajectoryProbe session --dump-windows`, no video needed here) through `ShotAnalyzer`
        // under a named variant, and compares two replays with a paired statistical test.
        // `ShotBenchKit` holds the statistics and scoring so they can be unit-tested; `ShotBench`
        // is the CLI. Foundation + simd + ShotGeometry only, like FormEvalKit/FormEval.
        // `Resources/rim_*_found.json`: the auto-found rim traces (RimFinder, 2026-09-14), copied
        // byte-for-byte from `footage/2026-09-13/` so the `autoFoundTrace` variant needs no access to
        // that gitignored, multi-GB footage directory at replay time — the same "no video" property
        // every other variant has. See `Variants.swift`'s `AutoFoundRimTrace`.
        .target(name: "ShotBenchKit", dependencies: ["ShotGeometry"],
                resources: [.copy("Resources/rim_1764_found.json"), .copy("Resources/rim_1765_found.json"), .copy("Resources/rim_1766_found.json")]),
        .executableTarget(name: "ShotBench", dependencies: ["ShotGeometry", "ShotBenchKit"]),
        .testTarget(name: "ShotGeometryTests", dependencies: ["ShotGeometry", "ShotBenchKit"]),
        .testTarget(name: "FormEvalKitTests", dependencies: ["FormEvalKit", "ShotGeometry"]),
    ]
)
