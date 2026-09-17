# ArcLab iOS — basketball shot analysis from video

Native iOS app that measures shooting mechanics from video for serious HS/college players.
Fully on-device. The product is repeatability and self-comparison, not absolute accuracy:
variance, make/miss separation, within-session drift, change over months — bucketed by shot
type and distance. See `docs/BRIEF.md` for the full brief and `docs/PHASE1-REPORT.md` for the
current state. `docs/DESIGN-MEMO-2026-09-13.md` is the product/design proposal with simulation numbers.

## Layout

```
Packages/ShotGeometry/      Pure Swift (Foundation + simd only). Geometry, physics, statistics.
  Sources/ShotGeometry/     Library: calibration, shot plane, trajectory fit, release detection, metrics, simulator
  Sources/GeometryHarness/  Phase 1 gate harness (prints the recovery table)       swift run -c release GeometryHarness
  Sources/GeometryChecks/   Full assertion suite as an executable (no XCTest needed) swift run GeometryChecks
  Sources/GeometryDebug/    One-shot inspector for a single simulated draw            .build/debug/GeometryDebug <fps> <view°> <noise px> [θ v h L dist height seed]
  Tests/ShotGeometryTests/  XCTest gate tests                                          swift test
Packages/ShotVideo/         AVFoundation + Vision layer (macOS 26 / iOS 26): frame reader with real PTS, Vision trajectory
  Sources/ShotVideo/        tracker, synthetic clip renderer, detector scorer                     swift build -c release
  Sources/TrajectoryProbe/  CLI: probe | track | frame | synth | eval                             .build/release/TrajectoryProbe
docs/                       Brief, phase reports, decisions, filming protocol, research, reference digests of the textbook
```

The app target (SwiftUI, AVFoundation, Vision, SwiftData) is added in Phase 3 and depends on
`ShotGeometry`; nothing in the package may import UIKit, Vision or AVFoundation.

## Phase status

| Phase | State |
|---|---|
| 0 Test footage | **Not done — human task.** ~200 reps at 240 fps from side/45°/head-on at FT/mid/three, plus ~50 handheld 30 fps; hand-labelled makes/misses. |
| 1 Synthetic geometry harness | **Gate passed** (2026-09-12). `docs/PHASE1-REPORT.md`. |
| 2 Ball detection | **Tooling built** (`Packages/ShotVideo`, `docs/PHASE2-PREP.md`): frame reader, Vision trajectory probe, synthetic clip + scorer. Vision alone misses ~60 % of frames at 240 fps; detector decision needs Phase 0 footage. |
| 3 Import, calibration, analysis | Not started. |
| 4–8 | Not started. |

## Running

```
cd Packages/ShotGeometry
swift test -Xswiftc -O                  # XCTest gate — 195 tests, 1-4 s. Use this one.
swift test                              # the same tests unoptimised, ~90 s
swift run GeometryChecks                # 95 assertions, exits non-zero on failure
swift run -c release GeometryHarness    # 50-draw gate table per scenario (~9 s)
```

On Xcode 27 the default SwiftPM build system code-signs the test bundle, and a build directory inside the iCloud-synced
Desktop folder picks up Finder/file-provider attributes that make that signing fail ("resource fork, Finder information,
or similar detritus not allowed"). Either build outside the synced tree
(`swift test -Xswiftc -O --scratch-path /tmp/arclab-sg`) or use `swift test --build-system native`.


`-Xswiftc -O` optimises the code under test without changing the build *configuration*, so
`assert` and `precondition` stay live and every `XCTAssert` is the assertion it was — it is the
same suite, 35-100× faster. (Plain `swift test` builds `-Onone`, where each `for i in 0..<n` goes
through a protocol-witness iterator; the numeric inner loops pay for that thousands of times per
gate scenario.) `--parallel` is *slower* here: SwiftPM forks one process per test class and the
whole suite finishes in less time than the forks take.
