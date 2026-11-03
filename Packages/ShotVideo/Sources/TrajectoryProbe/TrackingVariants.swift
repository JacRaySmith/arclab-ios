import Foundation
import ShotVideo

/// Named tracker parameter sets for `session --track-variants a,b,c`: every variant is tracked on the **same
/// decoded window** (planes, Core ML boxes and background are paid for once) and dumped to its own cache
/// directory, `<dump-dir>/<variant>/`, so `ShotBench` can score each and `compare` any two.
///
/// A variant is a function of the session's per-window options — the expected diameter, the time scale and the
/// command-line switches are already applied — so it changes only what it names. `base` is the identity: the
/// tracker exactly as the app ships it.
struct TrackingVariant: Sendable {
    let name: String
    let summary: String
    let apply: @Sendable (BallDetectorOptions) -> BallDetectorOptions

    static let base = TrackingVariant(name: "base", summary: "the shipping tracker, unchanged") { $0 }

    /// The backward pass uses the forward linker (parabolic prediction, growing gate, gap tolerance, relaxed
    /// near-prediction blobs) instead of a nearest-blob walk that ends at the first empty frame, and may reach
    /// 0.5 s back instead of 0.33 s.
    static let backLink = TrackingVariant(name: "backLink", summary: "backward extension by the same linker as the forward pass, up to 0.5 s back, blobs only") { o in
        var o = o; o.backwardLinker = true; o.extendBackSeconds = 0.5; return o
    }
    /// As `backLink`, and the backward pass may also take a Core ML box that no blob refines.
    static let backLinkBoxes = TrackingVariant(name: "backLinkBoxes", summary: "backLink, and Core ML boxes are allowed on the backward pass") { o in
        var o = backLink.apply(o); o.backwardAllowsBoxes = true; return o
    }
    /// Every ball-sized Core ML box in the window seeds a forward link, not only the scanner's positions.
    static let boxSeeds = TrackingVariant(name: "boxSeeds", summary: "forward links seeded from every ball-sized Core ML box (confidence ≥ 0.5), longest track wins") { o in
        var o = o; o.seedFromCoreMLBoxes = true; return o
    }
    /// After assembly, walk both ends outwards along the track's own projected parabola, taking relaxed blobs
    /// within 0.8 D of the prediction.
    static let extend = TrackingVariant(name: "extend", summary: "parabola walk from both ends of the assembled track, relaxed blobs within 0.8 D, up to 0.5 s back") { o in
        var o = o; o.parabolaExtend = true; o.extendBackSeconds = 0.5; return o
    }
    /// The linker may go 0.12 s (14 frames at 120 fps) without evidence before the track ends, instead of 0.05 s.
    static let gap = TrackingVariant(name: "gap", summary: "maxGapSeconds 0.05 → 0.12") { o in
        var o = o; o.maxGapSeconds = 0.12; return o
    }
    /// The relaxed finder accepts streaks up to aspect 3.2 (motion blur elongates a fast ball along its motion).
    static let aspect = TrackingVariant(name: "aspect", summary: "relaxed finder aspect ceiling 2.2 → 3.2 for blurred, fast frames") { o in
        var o = o; o.relaxedMaxAspect = 3.2; return o
    }
    /// A track may stay alive while the ball is above the top of the frame for 2.5 s instead of 1.0 s. A three
    /// from a camera tilted low leaves the frame for longer than a second (`IMG_1766@1060.8`: 1.4 s).
    static let offframe = TrackingVariant(name: "offframe", summary: "maxOffframeSeconds 1.0 → 2.5: survive a longer excursion above the frame") { o in
        var o = o; o.maxOffframeSeconds = 2.5; return o
    }
    /// Every lever at once (the backward pass without boxes).
    static let all = TrackingVariant(name: "all", summary: "backLink + boxSeeds + extend + gap + aspect") { o in
        var o = o
        o.backwardLinker = true; o.extendBackSeconds = 0.5
        o.seedFromCoreMLBoxes = true
        o.parabolaExtend = true
        o.maxGapSeconds = 0.12
        o.relaxedMaxAspect = 3.2
        return o
    }
    /// Every lever, and boxes on the backward pass.
    static let allBoxes = TrackingVariant(name: "allBoxes", summary: "all, and Core ML boxes are allowed on the backward pass") { o in
        var o = all.apply(o); o.backwardAllowsBoxes = true; return o
    }

    static let known: [TrackingVariant] = [base, backLink, backLinkBoxes, boxSeeds, extend, gap, aspect, offframe, all, allBoxes]
    static func named(_ name: String) -> TrackingVariant? { known.first { $0.name == name } }
}
