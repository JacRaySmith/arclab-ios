# ArcLab iOS — basketball shot analysis from video

Native iOS app that measures shooting mechanics from video for serious HS/college players.
Fully on-device. The product is repeatability and self-comparison, not absolute accuracy:
variance, make/miss separation, within-session drift, change over months — bucketed by shot
type and distance. `CLAUDE.md` has the reading order. `docs/BRIEF.md` is the full brief; `docs/HANDOFF.md`'s first
section is the current state; `docs/PIPELINE.md` + `docs/EXPERIMENTS.md` are how anything here is
measured and what has been tried. `docs/PHASE1-REPORT.md` is the synthetic gate every build is still
compared against byte for byte.

## Layout

```
Packages/ShotGeometry/      Pure Swift (Foundation + simd only). Geometry, physics, statistics.
  Sources/ShotGeometry/     Library: calibration, shot plane, trajectory fit, release detection, metrics, simulator
  Sources/GeometryHarness/  Phase 1 gate harness (prints the recovery table)       swift run -c release GeometryHarness
  Sources/GeometryChecks/   Full assertion suite as an executable (no XCTest needed) swift run GeometryChecks
  Sources/GeometryDebug/    One-shot inspector for a single simulated draw            .build/debug/GeometryDebug <fps> <view°> <noise px> [θ v h L dist height seed]
  Sources/ShotBenchKit/     Replays a cached corpus under a named variant; paired McNemar comparison
  Sources/ShotBench/        CLI: run | compare | azimuth                                   .build/release/ShotBench
  Tests/ShotGeometryTests/  XCTest gate tests                                          swift test
Packages/ShotVideo/         AVFoundation + Vision layer (macOS 26 / iOS 26): frame reader with real PTS, Vision trajectory
  Sources/ShotVideo/        tracker, synthetic clip renderer, detector scorer                     swift build -c release
  Sources/TrajectoryProbe/  CLI: probe | track | frame | analyze | session | body | form | spin    .build/release/TrajectoryProbe
docs/                       Brief, phase reports, decisions, filming protocol, research, reference digests of the textbook
```

The app itself is `App/` (SwiftUI, AVFoundation, Vision), built with XcodeGen from `App/project.yml`
and depending on both packages. Nothing in `ShotGeometry` may import UIKit, Vision or AVFoundation.
`App/README.md` describes what each screen does.

## Phase status

Updated 2026-09-27. The table below used to say Phase 3 was "not started" while 1.4.1 was running on
the user's phone; it is kept only because `docs/BRIEF.md` §8 numbers its gates this way.

| Phase | State |
|---|---|
| 0 Test footage | **Done, partially.** Three clips filmed 2026-09-13 (`footage/2026-09-13/`), 98 shot windows extracted and all of them hand-labelled `shot`/`notShot`/`unsure`. Still owed by the user: a 30–45° off-line clip, a close-up form clip, a footwork clip, a behind clip with tape for spin, and the second angle for multi-view. |
| 1 Synthetic geometry harness | **Gate passed** (2026-09-12), and still passing byte-identically — `docs/PHASE1-REPORT.md`. |
| 2 Ball detection | **Shipped.** Core ML `ArcLabBallModel` plus a classical blob/template tracker (`BallDetector.swift`), an automatic rim finder, and a whole-clip arrival scanner. No Phase 2 report was ever written — `docs/PHASE2-PREP.md` is the measurement log that stands in for it. |
| 3 Import, calibration, analysis | **Shipped.** On the phone as 1.4.1 (4). Precision on the labelled corpus is 100 %; recall is 57–65 % depending on variant, and raising it is the open problem. |
| 4–8 | Partly shipped ahead of their numbering: practice planning, the shot doctor, the curriculum, a jump test, game-film tagging and an IQ trainer are all in the app. No phase report exists for any of them. |

## Running

```
cd Packages/ShotGeometry
swift test -Xswiftc -O                  # XCTest gate — 448 + 27 tests. Use this one.
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
