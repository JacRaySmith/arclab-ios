import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Vision
import simd
import ShotGeometry

// ================================================================================================
// MARK: - Finding shots in a form clip, from the body alone
// ================================================================================================
//
// A **form clip** is the close-up the filming guide asks for: the phone 3–4 m away, side-on, the
// whole shooter in frame, 240 fps, **and no rim**. Everything the session pipeline uses to find a
// shot is therefore missing — there is no rim to calibrate against, no arrival to scan for, and the
// ball leaves the top of the frame a few frames after it leaves the hand.
//
// What is left is the body, and the body is enough to *find* a shot: the shooting wrist rises from
// the waist, **holds still** at the set position, drives up, and its highest point is the release
// (measured, `docs/PHASE2-PREP.md` "Body model, iteration 3": the wrist rises 0.000 to −0.009 m
// after the ball leaves, against a 0.36–0.37 m rise into it). So this scanner samples 2-D pose
// across the whole clip, builds one scalar per sample — how far the higher wrist is above the
// shoulder line, **in the shooter's own torso spans** so it survives any camera distance — and
// reads the rise-and-release pattern off it.
//
// Nothing here calibrates, scales or measures a shot. It hands `BodyTracker` a window and a release
// candidate; every number a shooter sees still comes from the body model downstream.

// MARK: - Options

public struct FormClipScanOptions: Sendable {
    public var startTime: Double = 0
    public var endTime: Double = .infinity
    /// File seconds per real second (1 for the app's own 240 fps recordings, 4 for a 120 fps clip
    /// written at 30).
    public var timeScale: Double = 1
    /// Sample the pose at about this rate in **real** time. 30 Hz puts ~8 samples inside the
    /// shortest set plateau this shooter produced (133 ms) and ~9 across the 305 ms set→release
    /// drive, which is what the plateau and the rise need; the release instant is refined later at
    /// the full frame rate by `BodyTracker`, never by this pass.
    public var sampleRateHz: Double = 30
    /// Render the frame at this fraction before handing it to the pose request. **1.0, measured:**
    /// iteration 3 swept the same lever on the body stage (`cropRenderScale`) and Vision resizes the
    /// input itself, so 0.7 left the request at 9.6 ms/frame against 9.0 at full size. Downscaling
    /// buys nothing and costs a render, so the default hands the decoded buffer straight over; the
    /// option stays so the measurement can be repeated.
    public var renderScale: Double = 1.0
    /// A 2-D point below this confidence is not used, the same floor the body model uses.
    public var minimumConfidence: Double = 0.3
    /// How far the wrist must rise above its lowest point in the lookback for the rise to be a shot,
    /// in the shooter's own torso spans (mid-shoulder to mid-hip). A free throw lifts the wrist from
    /// about chest height to above the head, which is 0.9–1.6 spans.
    public var minimumRiseTorsoSpans: Double = 0.55
    /// A rise slower than this is not one shot's drive — it is the shooter walking, catching a pass,
    /// or raising the ball to look at it.
    public var maximumRiseSeconds: Double = 1.5
    /// The wrist's high point must sit at least this many torso spans **above the shoulder line**.
    /// Measured on the 240 fps free-throw clip: every one of the 27 free throws released with the
    /// wrist 0.80–0.98 spans above the shoulders, and none of the nine non-shots the earlier rule
    /// reported (a dribble, a walk with the ball, a catch at the chest, a ball picked up off the
    /// floor) lifted it above −0.13. A shooter who releases from the forehead is still ≈ 0.5 above.
    public var minimumApexAboveShoulderSpans: Double = 0.35
    /// After the high point the wrist must stay above **half** its apex height for at least this
    /// long — the follow-through held. Measured: the 23 free throws hold it for more than a second;
    /// the overhead catch of a rebound held 200 ms (the ball was brought down to the chest) and the
    /// five quick tips from under the rim 100–200 ms. 0.3 s sits between, with the margin on the
    /// side of the shot: even a snapped-down follow-through takes longer than that to reach the chest.
    public var minimumExtensionSeconds: Double = 0.3
    /// "Still" is a rate at or below this fraction of the drive's fastest rate — the same rule and
    /// the same number as `BodyKinematicsOptions.quietRateFraction`, so the set the scanner names is
    /// the set the body model re-reads at full frame rate downstream.
    public var quietRateFraction: Double = 0.08
    /// Kept for the CLI's `--stillness` sweep only: no longer part of the rule.
    public var setStillnessSpans: Double = 0.06
    /// An elbow at or above this confidence counts as seen, for the camera-side count the notes
    /// report (`cameraSide`). It is **information, not the decision**: on the reference clip the
    /// count picked the wrong hand (8892 left against 8702 right, on a right-handed shooter).
    public var cameraSideElbowConfidence: Double = 0.5
    /// The set plateau must sit at least this many torso spans below the apex, so the still frames
    /// at the top of the follow-through are never read as the set.
    public var setBelowApexSpans: Double = 0.15
    /// Require a set plateau for a window to count as a shot. **On by default, measured:** on the
    /// 240 fps reference clip every one of the 23 free throws from the line holds a set for
    /// 333–600 ms, while the five quick shots from under the rim (ball-side release angles 75–96°,
    /// flights of 0.2–0.8 m: tips and put-backs) and the one overhead catch have none. A form clip
    /// measures the set shot, so those are refused with the reason, not pooled into its mean form.
    /// Off: a rise with no plateau is still reported, with the reason on the window.
    public var requireSetPlateau: Bool = true
    /// The drive from the set position to the high point may be at most this many torso spans. A
    /// set shot drives 0.35–0.5 spans on the reference shooter (the set is already at the forehead);
    /// the overhead catch that survived every other gate went from a 100 ms hold at the waist to
    /// the apex in one 1.3-span reach.
    public var maximumDriveSpans: Double = 1.0
    /// The set position is the last run of stillness at least this long before the drive
    /// (`BodyKinematicsOptions.minimumSetPlateauSeconds`, the same 80 ms, for the same reason).
    public var minimumSetPlateauSeconds: Double = 0.08
    /// Two apexes closer than this are the same shot seen twice.
    public var minimumShotSpacingSeconds: Double = 3.0
    /// The analysis window around the apex, in real seconds — the dip-to-follow-through span the
    /// body stage already uses.
    public var lookbackSeconds: Double = 1.5
    public var tailSeconds: Double = 0.4
    public init() {}
}

// MARK: - What the pass saw

/// One sampled frame of the scan: the scalar the shot detector runs on, plus the pixels behind it.
public struct FormClipSample: Sendable, Codable {
    /// A 2-D joint in full-frame pixels with Vision's confidence.
    public struct Joint: Sendable, Codable {
        public var u: Double, v: Double, c: Double
        public init(u: Double, v: Double, c: Double) { self.u = u; self.v = v; self.c = c }
        public var uv: SIMD2<Double> { SIMD2(u, v) }
    }
    public var fileTime: Double
    public var realTime: Double
    public var frameIndex: Int
    /// The wrist the height scalar was read from, in full-frame pixels: the shooting side's wrist
    /// when it was confident on this frame, else the other one (`FormClipScanner.resolve`).
    public var wristU: Double
    public var wristV: Double
    /// Which side that wrist was ("left"/"right").
    public var wristSide: String
    /// Mid-shoulder to mid-hip, pixels: the scale bar every height below is divided by.
    public var torsoSpanPx: Double
    /// (mid-shoulder v − wrist v) ÷ torso span. Positive = the wrist is above the shoulder line.
    public var wristHeightSpans: Double
    /// Elbow of the same side, when it was confident: the seed bias toward the ball needs it.
    public var elbowU: Double?
    public var elbowV: Double?
    /// Both wrists and both elbows as Vision returned them (confidence ≥ the scan's floor), so the
    /// shooting side is one vote over the whole clip and not a per-frame guess.
    public var leftWrist: Joint?
    public var rightWrist: Joint?
    public var leftElbow: Joint?
    public var rightElbow: Joint?
    /// Mid-shoulder row, pixels.
    public var midShoulderV: Double?
    /// Bounding box of every confident 2-D joint on this frame, `[minU, minV, maxU, maxV]` — what a
    /// close-up crop has to contain.
    public var bodyBox: [Double]?
    public init(fileTime: Double, realTime: Double, frameIndex: Int, wristU: Double, wristV: Double,
                wristSide: String, torsoSpanPx: Double, wristHeightSpans: Double,
                elbowU: Double? = nil, elbowV: Double? = nil,
                leftWrist: Joint? = nil, rightWrist: Joint? = nil, leftElbow: Joint? = nil, rightElbow: Joint? = nil,
                midShoulderV: Double? = nil, bodyBox: [Double]? = nil) {
        self.fileTime = fileTime; self.realTime = realTime; self.frameIndex = frameIndex
        self.wristU = wristU; self.wristV = wristV; self.wristSide = wristSide
        self.torsoSpanPx = torsoSpanPx; self.wristHeightSpans = wristHeightSpans
        self.elbowU = elbowU; self.elbowV = elbowV
        self.leftWrist = leftWrist; self.rightWrist = rightWrist; self.leftElbow = leftElbow; self.rightElbow = rightElbow
        self.midShoulderV = midShoulderV; self.bodyBox = bodyBox
    }
}

/// One shot the body found, as a window and a release candidate.
public struct FormClipWindow: Sendable, Codable, Identifiable {
    public var id: Int
    /// File seconds, what `BodyTracker.run` takes.
    public var startFile: Double
    public var endFile: Double
    /// Real seconds. The wrist's highest point — the release candidate before the ball is consulted.
    public var apexRealTime: Double
    /// Real seconds, the wrist's fastest upward moment on the drive.
    public var peakRateRealTime: Double?
    /// The last frame of the set plateau: the moment the hand leaves the set position. Nil with a
    /// reason when no run of stillness long enough sits before the drive.
    public var setRealTime: Double?
    public var setUnavailableReason: String?
    /// How long the plateau lasted, real seconds.
    public var setPlateauSeconds: Double?
    /// How far the wrist rose into the apex, in torso spans: the evidence this is a shot.
    public var riseSpans: Double
    public var riseSeconds: Double
    /// "left"/"right", voted over the drive.
    public var shootingSide: String
    /// The shooter's torso span in pixels at the apex — the number that says how close the camera was.
    public var torsoSpanPx: Double
    public var notes: [String]

    public init(id: Int, startFile: Double, endFile: Double, apexRealTime: Double,
                peakRateRealTime: Double?, setRealTime: Double?, setUnavailableReason: String?,
                setPlateauSeconds: Double?, riseSpans: Double, riseSeconds: Double,
                shootingSide: String, torsoSpanPx: Double, notes: [String]) {
        self.id = id; self.startFile = startFile; self.endFile = endFile
        self.apexRealTime = apexRealTime; self.peakRateRealTime = peakRateRealTime
        self.setRealTime = setRealTime; self.setUnavailableReason = setUnavailableReason
        self.setPlateauSeconds = setPlateauSeconds
        self.riseSpans = riseSpans; self.riseSeconds = riseSeconds
        self.shootingSide = shootingSide; self.torsoSpanPx = torsoSpanPx; self.notes = notes
    }
}

/// A wrist high point the pattern looked at and turned down, with the sentence that turned it
/// down — so an over- or under-detection can be read off the CLI instead of guessed at.
public struct FormClipRejectedCandidate: Sendable, Codable {
    public var apexRealTime: Double
    public var riseSpans: Double
    public var apexAboveShoulderSpans: Double
    public var reason: String
    public init(apexRealTime: Double, riseSpans: Double, apexAboveShoulderSpans: Double, reason: String) {
        self.apexRealTime = apexRealTime; self.riseSpans = riseSpans
        self.apexAboveShoulderSpans = apexAboveShoulderSpans; self.reason = reason
    }
}

public struct FormClipScanResult: Sendable, Codable {
    public var windows: [FormClipWindow]
    /// Candidates the pattern refused (after the second pass), for the record.
    public var rejected: [FormClipRejectedCandidate] = []
    public var samples: [FormClipSample]
    /// "left"/"right": the shooting side, voted from the shots themselves (`shootingSide`: the wrist
    /// extended further from the body at the top of the rise). Nil when no shot showed both wrists;
    /// each window then carries whichever wrist rose.
    public var shootingSide: String?
    public var decodedFrames: Int
    public var analysedFrames: Int
    /// Frames on which Vision returned a usable shoulder/hip/wrist set.
    public var framesWithBody: Int
    public var wallSeconds: Double
    public var imageWidth: Int
    public var imageHeight: Int
    public var fileFrameRate: Double
    public var timeScale: Double
    public var notes: [String]
    public init(windows: [FormClipWindow], samples: [FormClipSample], shootingSide: String?, decodedFrames: Int, analysedFrames: Int,
                framesWithBody: Int, wallSeconds: Double, imageWidth: Int, imageHeight: Int,
                fileFrameRate: Double, timeScale: Double, notes: [String]) {
        self.windows = windows; self.samples = samples; self.shootingSide = shootingSide; self.decodedFrames = decodedFrames
        self.analysedFrames = analysedFrames; self.framesWithBody = framesWithBody; self.wallSeconds = wallSeconds
        self.imageWidth = imageWidth; self.imageHeight = imageHeight
        self.fileFrameRate = fileFrameRate; self.timeScale = timeScale; self.notes = notes
    }
}

// MARK: - The scan

public enum FormClipScanner {

    /// One decode pass over the clip, 2-D body pose on every Nth frame, then the wrist pattern.
    ///
    /// - Parameter progress: called with (real seconds reached, windows found so far) so a screen
    ///   can show something honest while a 6-minute clip is read.
    public static func scan(url: URL, options: FormClipScanOptions = FormClipScanOptions(),
                            progress: (@Sendable (Double, Int) -> Void)? = nil) async throws -> FormClipScanResult {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw VideoReaderError.noVideoTrack }
        let natural = try await track.load(.naturalSize)
        let imageSize = CGSize(width: abs(natural.width), height: abs(natural.height))
        let probe = try await VideoReader(url: url).quickProbe(maxFrames: 60)
        let fps = probe.measuredFrameRate > 0 ? probe.measuredFrameRate : Double(try await track.load(.nominalFrameRate))
        let scale = options.timeScale > 0 ? options.timeScale : 1
        // Sampling is specified in real time, so the same option means the same thing on a 120 fps
        // clip written at 30 and on a true 240 fps recording.
        let realFPS = fps / scale
        let step = max(1, Int((realFPS / max(options.sampleRateHz, 1)).rounded()))

        let reader = VideoReader(url: url)
        let end = options.endTime.isFinite ? options.endTime : (probe.trackDuration > 0 ? probe.trackDuration : 1e9)
        let range = CMTimeRange(start: CMTime(seconds: options.startTime, preferredTimescale: 600),
                                end: CMTime(seconds: end, preferredTimescale: 600))
        let request = DetectHumanBodyPoseRequest()
        let cropper = Cropper()
        let fullRect = CGRect(origin: .zero, size: imageSize)

        var samples: [FormClipSample] = []
        var decoded = 0, analysed = 0, withBody = 0
        var notes: [String] = []
        let t0 = Date()
        var lastProgress = Date.distantPast

        // Only the analysed frames are re-wrapped into a `CMSampleBuffer` (`VideoReader.forEachFrame(stride:)`);
        // the decoder still decodes every frame, but the ones this scan skips cost nothing beyond that.
        try await reader.forEachFrame(timeRange: range, stride: step) { frame in
            defer { decoded = frame.index + 1 }
            if frame.pts > end + 1e-6 { return false }
            guard let full = frame.pixelBuffer else { return true }
            analysed += 1
            // The same macOS 26 fact `PoseTracker` records: the body-pose request returns nothing for
            // a buffer carrying the decoder's `CVCleanAperture` attachment. Strip it, then put it back.
            let cleanAperture = CVBufferCopyAttachment(full, kCVImageBufferCleanApertureKey, nil)
            if cleanAperture != nil { CVBufferRemoveAttachment(full, kCVImageBufferCleanApertureKey) }
            defer { if let c = cleanAperture { CVBufferSetAttachment(full, kCVImageBufferCleanApertureKey, c, .shouldPropagate) } }

            let target: CVPixelBuffer = options.renderScale < 0.999
                ? (cropper.crop(full, to: fullRect, imageSize: imageSize, renderScale: options.renderScale) ?? full)
                : full
            let observations = (try? await request.perform(on: target)) ?? []
            guard let o = BodyTracker.choose2D(observations, targetSize: imageSize, origin: .zero, seed: nil) else { return true }

            func point(_ name: HumanBodyPoseObservation.JointName) -> SIMD2<Double>? {
                guard let j = o.joint(for: name), Double(j.confidence) >= options.minimumConfidence else { return nil }
                let q = j.location.toImageCoordinates(imageSize, origin: .upperLeft)
                return SIMD2(Double(q.x), Double(q.y))
            }
            guard let ls = point(.leftShoulder), let rs = point(.rightShoulder),
                  let lh = point(.leftHip), let rh = point(.rightHip) else { return true }
            let midShoulder = (ls + rs) / 2, midHip = (lh + rh) / 2
            let span = simd_length(midShoulder - midHip)
            guard span > 8 else { return true }
            func joint(_ name: HumanBodyPoseObservation.JointName) -> FormClipSample.Joint? {
                guard let j = o.joint(for: name), Double(j.confidence) >= options.minimumConfidence else { return nil }
                let q = j.location.toImageCoordinates(imageSize, origin: .upperLeft)
                return FormClipSample.Joint(u: Double(q.x), v: Double(q.y), c: Double(j.confidence))
            }
            let lw = joint(.leftWrist), rw = joint(.rightWrist)
            guard lw != nil || rw != nil else { return true }
            // The provisional wrist is the higher one; `resolve` rewrites it once the side is known.
            let w: (uv: SIMD2<Double>, side: String) = {
                if let l = lw, let r = rw { return r.v < l.v ? (r.uv, "right") : (l.uv, "left") }
                if let l = lw { return (l.uv, "left") }
                return (rw!.uv, "right")
            }()
            let le = joint(.leftElbow), re = joint(.rightElbow)
            let elbow = w.side == "left" ? le : re
            var box = [Double.infinity, .infinity, -.infinity, -.infinity]
            for name in o.availableJointNames {
                guard let j = joint(name) else { continue }
                box[0] = min(box[0], j.u); box[1] = min(box[1], j.v); box[2] = max(box[2], j.u); box[3] = max(box[3], j.v)
            }
            withBody += 1
            samples.append(FormClipSample(fileTime: frame.pts, realTime: frame.pts / scale,
                                          frameIndex: Int((frame.pts * fps).rounded()),
                                          wristU: w.uv.x, wristV: w.uv.y, wristSide: w.side,
                                          torsoSpanPx: span,
                                          wristHeightSpans: (midShoulder.y - w.uv.y) / span,
                                          elbowU: elbow?.u, elbowV: elbow?.v,
                                          leftWrist: lw, rightWrist: rw, leftElbow: le, rightElbow: re,
                                          midShoulderV: midShoulder.y,
                                          bodyBox: box[0].isFinite ? box : nil))
            if let progress, Date().timeIntervalSince(lastProgress) > 0.5 {
                lastProgress = Date()
                progress(frame.pts / scale, 0)
            }
            return true
        }

        if samples.isEmpty {
            notes.append("Vision found no shoulders, hips and wrist together on any sampled frame: the shooter may be outside the frame, cut off at the waist, or too small")
        } else if Double(withBody) / Double(max(1, analysed)) < 0.8 {
            notes.append(String(format: "the body was complete on only %.0f %% of sampled frames; a shot whose set or release falls in a gap can be missed",
                                100 * Double(withBody) / Double(max(1, analysed))))
        }
        let found = analyse(samples, options: options)
        samples = found.samples
        notes.append(found.sideNote)
        let windows = found.windows
        notes.append(String(format: "sampled every %d%@ frame of %.0f fps (%.0f Hz real) over %.0f s of file time",
                            step, step == 1 ? "" : "th", fps, realFPS / Double(step), end - options.startTime))
        if !found.rejected.isEmpty {
            notes.append(String(format: "%d other wrist high point%@ refused: %@",
                                found.rejected.count, found.rejected.count == 1 ? " was" : "s were",
                                found.rejected.map(\.reason).reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
                                    .sorted { $0.value > $1.value }.map { "\($0.value)× \($0.key)" }.joined(separator: "; ")))
        }
        progress?(end / scale, windows.count)
        var result = FormClipScanResult(windows: windows, samples: samples, shootingSide: found.side, decodedFrames: decoded, analysedFrames: analysed,
                                        framesWithBody: withBody, wallSeconds: Date().timeIntervalSince(t0),
                                        imageWidth: Int(imageSize.width), imageHeight: Int(imageSize.height),
                                        fileFrameRate: fps, timeScale: scale, notes: notes)
        result.rejected = found.rejected
        return result
    }

    // MARK: The pattern — pure, so it can be re-run on a saved sample series without a decode

    /// Rise-and-release windows from the sampled wrist height. Pure: the same samples always give
    /// the same windows, which is how the thresholds below were swept on real footage.
    public static func windows(from samples: [FormClipSample],
                               options: FormClipScanOptions = FormClipScanOptions()) -> [FormClipWindow] {
        analyse(samples, options: options).windows
    }

    /// The whole pattern: a first pass on whichever wrist was higher finds the shots, the shots vote
    /// the shooting side (`shootingSide`), the series is re-read on that side's wrist, and a second
    /// pass returns the windows. The side is one vote for the clip, because a shooter does not
    /// change hands between free throws.
    public static func analyse(_ samples: [FormClipSample],
                               options: FormClipScanOptions = FormClipScanOptions())
        -> (windows: [FormClipWindow], rejected: [FormClipRejectedCandidate], samples: [FormClipSample], side: String?, sideNote: String) {
        let sorted = samples.sorted { $0.realTime < $1.realTime }
        let first = pass(sorted, options: options, side: nil)
        let vote = shootingSide(sorted, apexes: first.windows.map(\.apexRealTime), options: options)
        guard let side = vote.side else {
            return (first.windows, first.rejected, sorted, nil, vote.note)
        }
        let resolved = resolve(sorted, side: side, options: options)
        let second = pass(resolved, options: options, side: side)
        return (second.windows, second.rejected, resolved, side, vote.note)
    }

    /// The shooting hand, from the shots themselves: at the top of the rise the shooting arm is
    /// extended toward the basket and the guide hand has fallen back toward the head, so the
    /// shooting wrist is the one further from the body's own centre line. Voted over every shot
    /// found, on frames where both wrists were confident and the two differed by at least a tenth
    /// of a torso span.
    ///
    /// **Measured, and the camera side is deliberately not used.** On the 240 fps reference clip the
    /// phone stood on the shooter's right — his shooting-hand side, as the guide asks — and this rule
    /// picked the right hand on 27 of the 31 shots that showed both wrists. The elbow-confidence
    /// count the session path uses (`PoseMetrics2D.cameraSide`) said *left* on the same clip (8892
    /// confident left elbows against 8702 right: Vision reports both sides on a 9 m view), which is
    /// the "left hand" the earlier CLI run printed. So when no shot offers both wrists the side is
    /// **unknown**, each window carries whichever wrist rose, and the note says so; nothing guesses.
    public static func shootingSide(_ samples: [FormClipSample], apexes: [Double],
                                    options: FormClipScanOptions = FormClipScanOptions()) -> (side: String?, note: String) {
        var left = 0, right = 0
        for t in apexes {
            guard let s = samples.min(by: { abs($0.realTime - t) < abs($1.realTime - t) }),
                  abs(s.realTime - t) <= 0.1,
                  let l = s.leftWrist, let r = s.rightWrist, let box = s.bodyBox, s.torsoSpanPx > 0 else { continue }
            let cx = (box[0] + box[2]) / 2
            let dl = abs(l.u - cx), dr = abs(r.u - cx)
            guard abs(dl - dr) >= 0.1 * s.torsoSpanPx else { continue }
            if dl > dr { left += 1 } else { right += 1 }
        }
        let elbows = cameraSide(samples, options: options)
        let elbowNote = elbows.side == nil ? ""
            : String(format: " (the elbow count, %d left against %d right, is not used: it is the side Vision saw better, which on a 9 m view is not the shooting side)", elbows.left, elbows.right)
        if left + right > 0 {
            let side = left > right ? "left" : "right"
            return (side, String(format: "shooting side: %@ — the wrist extended further from the body at the top of the rise, on %d of %d shots that showed both wrists%@",
                                 side, max(left, right), left + right, elbowNote))
        }
        return (nil, "shooting side unknown: no shot showed both wrists at its top, so each window uses whichever wrist rose" + elbowNote)
    }

    /// One pass of the pattern on the samples as given.
    ///
    /// A shot, in this scalar, is: the wrist **rises** by more than half a torso span within 1.5 s,
    /// to a high point **above the shoulder line**, and **holds** that extension — stays above half
    /// its apex height for 0.2 s — with the last such high point at least 3 s from the next. Each
    /// gate names what it turns down, because the earlier rule (rise alone) reported nine dribbles,
    /// catches and walks as shots on a 387 s clip of 28.
    static func pass(_ s: [FormClipSample], options: FormClipScanOptions, side: String?)
        -> (windows: [FormClipWindow], rejected: [FormClipRejectedCandidate]) {
        guard s.count >= 8 else { return ([], []) }
        let t = s.map(\.realTime)
        let raw = s.map(\.wristHeightSpans)
        let h = smoothed(raw, halfWidth: 2)
        let hs = smoothed(raw, halfWidth: 1)
        // A three-point slope (±33 ms at 30 Hz): a five-point one smears the end of the plateau into
        // the drive and dates the set a sample or two early.
        let rate = derivative(hs, t: t, halfWindow: 1)
        let dt = medianInterval(t)
        let peakHalf = max(1, Int((0.10 / max(dt, 1e-6)).rounded()))

        // 1. Local maxima of the smoothed wrist height. A plateau of equal values keeps its first index.
        var apexes: [Int] = []
        for i in h.indices {
            let lo = max(0, i - peakHalf), hi = min(h.count - 1, i + peakHalf)
            var isMax = true
            for j in lo...hi where j != i {
                if h[j] > h[i] || (h[j] == h[i] && j < i) { isMax = false; break }
            }
            if isMax { apexes.append(i) }
        }

        // 2. Each apex keeps the rise that led into it, and is refined onto the lightly smoothed
        //    series: the ±67 ms smoothing that finds the maximum reliably also dates it late. Every
        //    gate runs here, per candidate, *before* the clustering in step 3 — a catch two seconds
        //    after a quick shot must not win the cluster and hide the shot.
        struct Candidate {
            var apex: Int; var low: Int; var rise: Double; var seconds: Double
            var riseStart: Int; var setIndex: Int?; var plateau: Double?; var setReason: String?
        }
        var candidates: [Candidate] = []
        var rejected: [FormClipRejectedCandidate] = []
        for i in apexes {
            var a = i
            for j in max(0, i - peakHalf)...min(hs.count - 1, i + peakHalf) where hs[j] > hs[a] { a = j }
            var lowIndex = a
            var lowValue = h[a]
            var j = a - 1
            while j >= 0, t[a] - t[j] <= options.lookbackSeconds {
                if h[j] < lowValue { lowValue = h[j]; lowIndex = j }
                j -= 1
            }
            let rise = h[a] - lowValue
            let seconds = t[a] - t[lowIndex]
            // The gates, cheapest first. A rise below the floor is the resting hand's noise and is
            // not recorded; everything past that is, with its reason.
            guard rise >= options.minimumRiseTorsoSpans, seconds > 0 else { continue }
            func refuse(_ why: String) {
                rejected.append(FormClipRejectedCandidate(apexRealTime: t[a], riseSpans: rise, apexAboveShoulderSpans: hs[a], reason: why))
            }
            guard seconds <= options.maximumRiseSeconds else {
                refuse(String(format: "the rise took %.1f s, longer than one drive", seconds)); continue
            }
            guard hs[a] >= options.minimumApexAboveShoulderSpans else {
                refuse(String(format: "the wrist's high point was %.2f torso lengths %@ the shoulder line, not above it: a dribble, a catch at the chest or a walk with the ball",
                              abs(hs[a]), hs[a] < 0 ? "below" : "above")); continue
            }
            // The extension held: how long after the apex the wrist stays above half its height.
            let holdFloor = 0.5 * hs[a]
            var held = 0.0
            var k = a + 1
            while k < hs.count, hs[k] >= holdFloor { held = t[k] - t[a]; k += 1 }
            if k >= hs.count, held < options.minimumExtensionSeconds {
                // The series ended while the wrist was still up: not evidence against it.
                held = options.minimumExtensionSeconds
            }
            guard held >= options.minimumExtensionSeconds else {
                refuse(String(format: "the wrist came back down within %.0f ms of its high point: a catch or a tip, not a held follow-through", 1000 * held)); continue
            }

            // The drive starts where the wrist first leaves the bottom of the rise by a tenth of it.
            var riseStart = lowIndex
            let threshold = h[lowIndex] + 0.1 * rise
            for j in lowIndex...a where h[j] <= threshold { riseStart = j }

            let floorIndex: Int = {
                var j = lowIndex
                while j > 0, t[a] - t[j - 1] <= options.lookbackSeconds { j -= 1 }
                return j
            }()
            var tailIndex = a
            while tailIndex + 1 < t.count, t[tailIndex + 1] - t[a] <= options.tailSeconds { tailIndex += 1 }

            // The set position, by iteration 3's rule (`BodyKinematics`, "set point"): "still" is a
            // rate at or below `quietRateFraction` of the fastest rate in the window; the set is the
            // **last** run of still samples before the apex that lasts at least the minimum, and the
            // set point is that run's last sample — the moment the hand leaves the set. The run must
            // also sit `setBelowApexSpans` under the apex, because the rate is zero at the top by
            // construction. The earlier range test (height within 0.06 spans) let the first sample of
            // the drive into the plateau and dated the set 130–170 ms before the apex on every free
            // throw; the rate rule puts it 170–200 ms before, where the 120 Hz model finds it.
            var peakRate = 0.0
            for j in floorIndex...tailIndex { peakRate = max(peakRate, abs(rate[j])) }
            let quiet = peakRate * options.quietRateFraction
            let ceiling = h[a] - options.setBelowApexSpans
            var setIndex: Int? = nil
            var plateau: Double? = nil
            if peakRate > 0 {
                var runs: [(lo: Int, hi: Int)] = []
                var open: Int? = nil
                for j in floorIndex..<a {
                    let still = abs(rate[j]) <= quiet && hs[j] <= ceiling
                    if still { if open == nil { open = j } }
                    else if let o = open { runs.append((o, j - 1)); open = nil }
                }
                if let o = open { runs.append((o, a - 1)) }
                if let last = runs.last(where: { t[$0.hi] - t[$0.lo] >= options.minimumSetPlateauSeconds }) {
                    setIndex = last.hi
                    plateau = t[last.hi] - t[last.lo]
                }
            }
            if let si = setIndex, h[a] - hs[si] > options.maximumDriveSpans {
                refuse(String(format: "the hand went %.1f torso lengths from its last still position to the high point in one motion: a reach or a catch, not a drive from a set", h[a] - hs[si]))
                continue
            }
            var setReason: String? = nil
            if setIndex == nil {
                setReason = String(format: "the wrist never held still for %.0f ms between its low point and the drive, so there is no set position: a quick shot, a tip or a catch, not a set shot",
                                   1000 * options.minimumSetPlateauSeconds)
                if options.requireSetPlateau { refuse(setReason!); continue }
            }
            candidates.append(Candidate(apex: a, low: lowIndex, rise: rise, seconds: seconds, riseStart: riseStart,
                                        setIndex: setIndex, plateau: plateau, setReason: setReason))
        }

        // 3. One shot per cluster: the biggest rise wins, and nothing within the spacing survives it.
        //    The end of the set plateau and the follow-through hold are both local maxima of the
        //    same shot; they are not recorded as refusals, because they are not events.
        var kept: [Candidate] = []
        for c in candidates.sorted(by: { $0.rise > $1.rise }) {
            if kept.contains(where: { abs(t[$0.apex] - t[c.apex]) < options.minimumShotSpacingSeconds }) { continue }
            kept.append(c)
        }
        kept.sort { t[$0.apex] < t[$1.apex] }
        // A refusal inside a kept shot's spacing is that shot's own plateau end or follow-through
        // wobble (a local maximum with the waist as its "last still position"), not an event.
        rejected.removeAll { r in kept.contains { abs(t[$0.apex] - r.apexRealTime) < options.minimumShotSpacingSeconds } }

        // 4. Turn each into a window.
        var out: [FormClipWindow] = []
        for c in kept {
            var notes: [String] = []
            if let why = c.setReason { notes.append(why) }

            // The fastest upward moment of the drive — after the set when there is one — the release
            // fallback when there is no ball.
            var peakIndex: Int? = nil
            let driveStart = max(c.riseStart, c.setIndex ?? c.riseStart)
            for j in driveStart...c.apex where peakIndex == nil || rate[j] > rate[peakIndex!] { peakIndex = j }

            // Which hand: the clip's one vote when there was one; else the wrist that rose.
            let side: String = side ?? {
                let sides = s[c.riseStart...c.apex].map(\.wristSide)
                let right = sides.filter { $0 == "right" }.count
                return right * 2 >= sides.count ? "right" : "left"
            }()

            let apexReal = t[c.apex]
            let scale = options.timeScale > 0 ? options.timeScale : 1
            out.append(FormClipWindow(id: out.count + 1,
                                      startFile: max(0, (apexReal - options.lookbackSeconds) * scale),
                                      endFile: (apexReal + options.tailSeconds) * scale,
                                      apexRealTime: apexReal,
                                      peakRateRealTime: peakIndex.map { t[$0] },
                                      setRealTime: c.setIndex.map { t[$0] },
                                      setUnavailableReason: c.setReason,
                                      setPlateauSeconds: c.plateau,
                                      riseSpans: c.rise, riseSeconds: c.seconds,
                                      shootingSide: side,
                                      torsoSpanPx: s[c.apex].torsoSpanPx,
                                      notes: notes))
        }
        rejected.sort { $0.apexRealTime < $1.apexRealTime }
        return (out, rejected)
    }

    // MARK: The side

    /// The side facing the camera, by the rule the session path uses (`PoseMetrics2D.cameraSide`):
    /// whichever elbow Vision reported at or above `cameraSideElbowConfidence` on more sampled
    /// frames. **Reported, never used to pick the shooting hand**: on the 240 fps reference clip it
    /// said left on a right-handed shooter filmed from his right. Nil on a series with no elbow data
    /// (an older saved series) or no confident elbow at all.
    public static func cameraSide(_ samples: [FormClipSample],
                                  options: FormClipScanOptions = FormClipScanOptions()) -> (side: String?, left: Int, right: Int) {
        let floor = options.cameraSideElbowConfidence
        let left = samples.filter { ($0.leftElbow?.c ?? 0) >= floor }.count
        let right = samples.filter { ($0.rightElbow?.c ?? 0) >= floor }.count
        guard left + right > 0 else { return (nil, 0, 0) }
        return (left > right ? "left" : "right", left, right)
    }

    /// Rewrites each sample's wrist, elbow and height scalar to `side`'s limb wherever Vision had it,
    /// keeping the other wrist only on frames where that limb was missing. A sample without the
    /// per-side joints (an older series) is returned unchanged.
    public static func resolve(_ samples: [FormClipSample], side: String,
                               options: FormClipScanOptions = FormClipScanOptions()) -> [FormClipSample] {
        samples.map { s in
            guard s.leftWrist != nil || s.rightWrist != nil else { return s }
            let own = side == "left" ? s.leftWrist : s.rightWrist
            let other = side == "left" ? s.rightWrist : s.leftWrist
            guard let w = own ?? other else { return s }
            let usedSide = own != nil ? side : (side == "left" ? "right" : "left")
            var out = s
            out.wristU = w.u; out.wristV = w.v; out.wristSide = usedSide
            let e = usedSide == "left" ? s.leftElbow : s.rightElbow
            out.elbowU = e?.u; out.elbowV = e?.v
            if let ms = s.midShoulderV, s.torsoSpanPx > 0 { out.wristHeightSpans = (ms - w.v) / s.torsoSpanPx }
            return out
        }
    }

    // MARK: Small numerics (kept here so the scanner needs nothing but Foundation and Vision)

    static func smoothed(_ x: [Double], halfWidth: Int) -> [Double] {
        guard halfWidth > 0, x.count > 2 * halfWidth else { return x }
        var out = x
        for i in x.indices {
            let lo = max(0, i - halfWidth), hi = min(x.count - 1, i + halfWidth)
            out[i] = x[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        }
        return out
    }

    /// Zero-phase local least-squares slope, the same shape `BodyKinematics` uses for its rates.
    static func derivative(_ x: [Double], t: [Double], halfWindow: Int) -> [Double] {
        var out = [Double](repeating: 0, count: x.count)
        guard x.count == t.count, x.count >= 3 else { return out }
        for i in x.indices {
            let lo = max(0, i - halfWindow), hi = min(x.count - 1, i + halfWindow)
            guard hi > lo else { continue }
            let n = Double(hi - lo + 1)
            let tm = t[lo...hi].reduce(0, +) / n
            let xm = x[lo...hi].reduce(0, +) / n
            var num = 0.0, den = 0.0
            for j in lo...hi { num += (t[j] - tm) * (x[j] - xm); den += (t[j] - tm) * (t[j] - tm) }
            out[i] = den > 0 ? num / den : 0
        }
        return out
    }

    static func medianInterval(_ t: [Double]) -> Double {
        guard t.count >= 2 else { return 1 }
        var d: [Double] = []
        for i in 1..<t.count { d.append(t[i] - t[i - 1]) }
        d.sort()
        return d[d.count / 2]
    }
}

// ================================================================================================
// MARK: - The release instant without a rim
// ================================================================================================

/// Where a form clip's release came from. The order is the order of preference, and the order of
/// precision: the ball leaving the hand is an event in the pixels; the wrist's own apex is a proxy
/// with a spread that has been measured against it.
public enum FormClipReleaseSource: String, Sendable, Codable {
    case ballLeftHand
    case wristApex
    case wristPeakVelocity
}

public struct FormClipRelease: Sendable, Codable {
    /// Real seconds.
    public var realTime: Double
    public var source: FormClipReleaseSource
    /// 1σ in **real seconds**, and never smaller than one sampled frame.
    public var sigmaSeconds: Double
    /// The sentence the card prints next to any number that depends on this instant.
    public var note: String
    public var ballSamplesUsed: Int
    public init(realTime: Double, source: FormClipReleaseSource, sigmaSeconds: Double, note: String, ballSamplesUsed: Int) {
        self.realTime = realTime; self.source = source; self.sigmaSeconds = sigmaSeconds
        self.note = note; self.ballSamplesUsed = ballSamplesUsed
    }
}

public enum FormClipReleaseEstimator {
    /// The ball must clear the wrist by this many of its own diameters to count as gone
    /// (`ReleaseFromPose.clearanceDiameters`, the rule the labelled free throws were checked against).
    public static let clearanceDiameters = 1.0
    /// "Rising" means the third following sample is at least this many pixels higher up the image.
    public static let risePx = 2.0
    /// A wrist below this confidence cannot place the hand.
    public static let wristConfidence = 0.3
    /// How far from the wrist's own highest point a ball-based release is allowed to sit before it is
    /// refused as the detector having latched onto something else.
    ///
    /// **Measured, not chosen** (2026-09-15, 23 free throws of the 240 fps clip, ball-flight release
    /// as the reference, body pass on every 2nd frame). The wrist's highest point sat within 3.0
    /// frames (12.7 ms) of the reference on all 23 (mean −0.6 frames, SD 1.3). The hand-seeded ball
    /// track's "left the hand" frame was within 3 frames on 15 of 20 — and on the other five it was
    /// 5–18 frames off, each time 17–79 ms from the wrist apex. So a ball candidate more than 15 ms
    /// from the apex contradicts the body fact that the apex *is* the release to ±13 ms, and it is
    /// refused; the earlier 100 ms gate let all five through.
    public static let maximumBallToApexSeconds = 0.015

    /// The release, from the ball if the ball can be seen leaving the hand, else from the wrist.
    ///
    /// - Parameters:
    ///   - timeline: the body pass over the window (real-time clock).
    ///   - ball: ball samples on the same real clock, in full-frame pixels. Empty is allowed and is
    ///     the normal case on a close-up clip where the ball leaves the frame.
    ///   - apexRealTime: the scanner's candidate, used only to bound the search.
    ///   - searchSeconds: how far either side of the apex a ball release may be found.
    ///   - wristApexSigma: the 1σ to attach to the wrist-apex fallback, in real seconds.
    ///
    /// **13 ms is measured, not assumed** (`docs/HANDOFF.md`, "Form-clip mode, validated
    /// (2026-09-15)"). On the 23 free throws of the 240 fps clip whose rim *is* in frame, the wrist's
    /// highest point read off the 120 Hz body pass sat within 12.7 ms (3 frames) of the ball-flight
    /// release on every shot, mean −2.4 ms, SD 5.5 ms. The number carried is the worst case seen,
    /// not the SD, because one shooter on one clip is not a population; and never less than one
    /// sampled frame.
    public static func estimate(timeline: BodyTimeline, ball: [BodyBallSample], apexRealTime: Double,
                                shootingSide: String?, searchSeconds: Double = 0.6,
                                wristApexSigma: Double = 0.013) -> (release: FormClipRelease?, reason: String?) {
        let frames = timeline.frames.sorted { $0.realTime < $1.realTime }
        guard !frames.isEmpty else { return (nil, "the body pass returned no frames, so there is no wrist to date the release from") }
        let frameFloor = frames.count >= 2 ? FormClipScanner.medianInterval(frames.map(\.realTime)) : 1.0 / 240

        // ---- 1. The ball leaving the shooting hand ------------------------------------------------
        /// Set when a candidate satisfied the rule but sat too far from the wrist's apex to be it.
        var ballFarFromApex: Double? = nil
        let samples = ball.filter { abs($0.t - apexRealTime) <= searchSeconds && $0.diameterPx > 0 }.sorted { $0.t < $1.t }
        if samples.count >= 4 {
            let tolerance = max(1.5 * frameFloor, 1e-4)
            for (n, b) in samples.enumerated() where n + 3 < samples.count {
                guard let f = nearest(frames, realTime: b.t, tolerance: tolerance) else { continue }
                var nearestWrist: (distance: Double, point: BodyPoint2D)? = nil
                for name in [Body2DPoint.leftWrist, Body2DPoint.rightWrist] {
                    guard let p = f.points2D[name], p.confidence >= wristConfidence else { continue }
                    let d = simd_length(SIMD2(b.u, b.v) - SIMD2(p.u, p.v))
                    if nearestWrist == nil || d < nearestWrist!.distance { nearestWrist = (d, p) }
                }
                guard let near = nearestWrist,
                      near.distance >= clearanceDiameters * b.diameterPx,
                      b.v <= near.point.v else { continue }
                let following = samples[(n + 1)...min(n + 3, samples.count - 1)].map(\.v)
                guard let last = following.last, last < b.v - risePx else { continue }
                guard abs(b.t - apexRealTime) <= maximumBallToApexSeconds else {
                    ballFarFromApex = b.t - apexRealTime
                    break
                }
                let sigma = max(frameFloor, FormClipScanner.medianInterval(samples.map(\.t)))
                return (FormClipRelease(realTime: b.t, source: .ballLeftHand, sigmaSeconds: sigma,
                                        note: String(format: "the release is the first frame on which the ball is a full diameter clear of the hand, above it and rising; ±%.0f ms is one sampled frame",
                                                     1000 * sigma),
                                        ballSamplesUsed: samples.count), nil)
            }
        }

        // ---- 2. The wrist's own highest point -----------------------------------------------------
        let side = shootingSide ?? "right"
        let wristName = side == "left" ? Body2DPoint.leftWrist : Body2DPoint.rightWrist
        var series: [(t: Double, v: Double)] = []
        for f in frames {
            let p = f.points2D[wristName] ?? f.points2D[side == "left" ? Body2DPoint.rightWrist : Body2DPoint.leftWrist]
            guard let p, p.confidence >= wristConfidence else { continue }
            series.append((f.realTime, p.v))
        }
        guard series.count >= 5 else {
            return (nil, "no analysed frame in this window carried a confident wrist, so neither the ball nor the hand can date the release")
        }
        var why = samples.isEmpty
            ? "the ball was never seen leaving the hand in this window — on a close-up clip it usually leaves the frame first — so the release is the wrist's own highest point"
            : "the ball track never showed the ball a full diameter clear of the hand, above it and rising, so the release is the wrist's own highest point"
        if let gap = ballFarFromApex {
            why = String(format: "the ball track did show the ball leaving a hand, but %.0f ms %@ the top of the wrist's rise, which is too far from it to be this shot's release; the release is the wrist's own highest point instead",
                         1000 * abs(gap), gap < 0 ? "before" : "after")
        }
        let smooth = FormClipScanner.smoothed(series.map(\.v), halfWidth: 2)
        if let i = smooth.indices.min(by: { smooth[$0] < smooth[$1] }) {
            let sigma = max(frameFloor, wristApexSigma)
            return (FormClipRelease(realTime: series[i].t, source: .wristApex, sigmaSeconds: sigma,
                                    note: String(format: "%@. Measured against the ball's own flight on 23 free throws where both were available, the wrist's high point sat within 13 ms of the release on every one (mean 2 ms early, spread 6 ms), so read this instant as ±%.0f ms — and every time on this card moves with it.",
                                                 why, 1000 * sigma),
                                    ballSamplesUsed: samples.count), nil)
        }
        return (nil, why + ", and the wrist's path had no highest point inside the window")
    }

    static func nearest(_ frames: [BodyFrame], realTime: Double, tolerance: Double) -> BodyFrame? {
        guard !frames.isEmpty else { return nil }
        var lo = 0, hi = frames.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if frames[mid].realTime < realTime { lo = mid + 1 } else { hi = mid }
        }
        var best = lo
        if lo > 0, abs(frames[lo - 1].realTime - realTime) < abs(frames[lo].realTime - realTime) { best = lo - 1 }
        return abs(frames[best].realTime - realTime) <= tolerance ? frames[best] : nil
    }
}

// ================================================================================================
// MARK: - A ball track with no rim to seed it
// ================================================================================================

/// `BallDetector` is a *seeded* tracker: the session pipeline seeds it from the rim scanner's
/// arrival candidates. A form clip has no rim, so the only thing that is certainly on the ball is
/// the **shooting hand** just before the release. This seeds from there and lets the linker do the
/// rest; where it finds nothing, the release falls back to the wrist and says so.
public enum FormClipBall {
    /// The ball's diameter as a fraction of the shooter's mid-shoulder-to-mid-hip span. A men's
    /// size-7 ball is 0.2438 m across and an adult's torso span is ≈ 1.7 ball diameters; this is a
    /// **search hint for the detector**, never a published measurement, and it is what lets the same
    /// options work at 9 m and at 3 m without being told the distance.
    public static let ballDiametersPerTorsoSpan = 0.58

    /// - Parameters:
    ///   - seeds: `(file pts, point on the ball)` — the shooting wrist, biased along the forearm.
    ///   - fps: the file's measured frame rate, the clock `BallDetection.frameIndex` counts in.
    public static func track(url: URL, start: Double, end: Double, fps: Double,
                             seeds: [(pts: Double, uv: SIMD2<Double>)],
                             expectedDiameterPx: Double,
                             options: BallDetectorOptions = BallDetectorOptions()) async throws -> [BallDetection] {
        var o = options
        o.expectedDiameterPx = max(8, expectedDiameterPx)
        var seedByFrame: [Int: SIMD2<Double>] = [:]
        for s in seeds { seedByFrame[Int((s.pts * fps).rounded())] = s.uv }
        guard !seedByFrame.isEmpty else { return [] }
        return try await BallDetector.run(url: url, start: start, end: end, seed: seedByFrame, fps: fps, options: o)
    }

    /// The seed points for a window: the shooting wrist over the last part of the drive, pushed
    /// `bias` forearm lengths past the wrist, because the ball sits past the hand, never behind it.
    public static func seeds(from samples: [FormClipSample], side: String,
                             realTimeRange: ClosedRange<Double>, bias: Double = 0.6) -> [(pts: Double, uv: SIMD2<Double>)] {
        samples.filter { realTimeRange.contains($0.realTime) }.map { s in
            let wrist = SIMD2(s.wristU, s.wristV)
            guard let eu = s.elbowU, let ev = s.elbowV else { return (s.fileTime, wrist) }
            let forearm = wrist - SIMD2(eu, ev)
            return (s.fileTime, wrist + bias * forearm)
        }
    }
}
