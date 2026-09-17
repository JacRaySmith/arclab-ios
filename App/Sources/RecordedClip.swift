import AVFoundation
import Foundation

/// One clip recorded by the app itself, plus everything the analysis would otherwise have to be told by
/// hand: the true frame rate and the lens's horizontal field of view.
///
/// Why this exists: today the shooter films in Camera.app, exports through Photos (which hands over a
/// slo-mo clip as a 30 fps composition), imports it, and then *types* a slow-motion factor and an hFOV.
/// Both of those are guesses, and a wrong factor puts `g_fit` at 4× or ¼ of 9.81. A clip recorded here is
/// written by `AVCaptureMovieFileOutput` with real timestamps — a 120/240 fps file, not a 30 fps
/// composition — and the numbers below are read from the `AVCaptureDevice.Format` that actually produced it.
///
/// Every clip is written twice: the `.mov`, and a sidecar `.json` with this struct next to it, so the
/// facts survive the file being moved, copied to the Mac, or read by anything that is not this app.
///
/// Nothing here is ever invented (CLAUDE.md rule 1). `measuredNominalFrameRate` is `nil` when the written
/// file could not be re-read, and the caller must say "unknown" rather than assume `requestedFrameRate`.
struct RecordedClip: Codable, Identifiable, Hashable, Sendable {
    /// Stable id, also the stem of both files on disk.
    var id: UUID
    /// File name only. The app container path changes between installs, so the absolute URL is never
    /// stored; `url` rebuilds it from `RecordedClip.recordingsDirectory`.
    var movieFileName: String
    var recordedAt: Date

    /// The frame rate the capture device was pinned to (`activeVideoMin/MaxFrameDuration`).
    var requestedFrameRate: Double
    /// `AVAssetTrack.nominalFrameRate` read back from the finished file. `nil` = the file could not be
    /// re-read; the analysis must not fall back to `requestedFrameRate` silently.
    var measuredNominalFrameRate: Double?
    /// Frames ÷ duration from the finished file, when both are known. A second, independent check on the
    /// time base: it disagrees with `measuredNominalFrameRate` when the format dropped frames (thermal).
    var measuredAverageFrameRate: Double?
    var durationSeconds: Double?

    /// Horizontal field of view of the *active format*, in degrees, from `AVCaptureDevice.Format.videoFieldOfView`.
    /// High-frame-rate formats are cropped, so this is usually narrower than the same camera's photo format
    /// (≈48° for 1080p HFR on the paired iPhone, against ≈64° for ordinary 1080p). This is the number the
    /// analysis needs; the UI must never make the shooter type it.
    var videoFieldOfViewDegrees: Double

    var pixelWidth: Int
    var pixelHeight: Int

    /// e.g. "iPhone15,2" (iPhone 14 Pro) — the hardware identifier, not the marketing name, because the
    /// lens geometry belongs to the hardware.
    var deviceModel: String
    /// "hevc" or "h264", whichever the movie output actually accepted.
    var videoCodec: String

    /// True when focus/exposure were locked before the recording started. A clip filmed without the lock
    /// can change the ball's size mid-flight, so the analysis is entitled to know.
    var focusLocked: Bool
    var exposureLocked: Bool

    /// Version of `docs/PHASE0-FILMING-PROTOCOL.md` this clip was filmed under.
    var protocolVersion: String

    /// Anything that was true of the recording and would change how a number should be read
    /// ("device got hot mid-clip", "only 60 fps was available").
    var warnings: [String]

    init(
        id: UUID = UUID(),
        movieFileName: String,
        recordedAt: Date = Date(),
        requestedFrameRate: Double,
        measuredNominalFrameRate: Double? = nil,
        measuredAverageFrameRate: Double? = nil,
        durationSeconds: Double? = nil,
        videoFieldOfViewDegrees: Double,
        pixelWidth: Int,
        pixelHeight: Int,
        deviceModel: String = RecordedClip.currentDeviceModel,
        videoCodec: String,
        focusLocked: Bool,
        exposureLocked: Bool,
        protocolVersion: String = "v1",
        warnings: [String] = []
    ) {
        self.id = id
        self.movieFileName = movieFileName
        self.recordedAt = recordedAt
        self.requestedFrameRate = requestedFrameRate
        self.measuredNominalFrameRate = measuredNominalFrameRate
        self.measuredAverageFrameRate = measuredAverageFrameRate
        self.durationSeconds = durationSeconds
        self.videoFieldOfViewDegrees = videoFieldOfViewDegrees
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.deviceModel = deviceModel
        self.videoCodec = videoCodec
        self.focusLocked = focusLocked
        self.exposureLocked = exposureLocked
        self.protocolVersion = protocolVersion
        self.warnings = warnings
    }

    // MARK: - Where the files live

    /// `Documents/ArcLab/Recordings`. Documents, not Caches: a gym session must not be evicted under
    /// storage pressure before it has been analysed.
    static var recordingsDirectory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ArcLab/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A fresh `.mov` URL for a recording that is about to start.
    static func newMovieURL(id: UUID) -> URL {
        recordingsDirectory.appendingPathComponent(id.uuidString).appendingPathExtension("mov")
    }

    var url: URL { RecordedClip.recordingsDirectory.appendingPathComponent(movieFileName) }
    var sidecarURL: URL { url.deletingPathExtension().appendingPathExtension("json") }

    var fileExists: Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: - Sidecar

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Writes the sidecar next to the movie.
    func saveSidecar() throws {
        try RecordedClip.encoder.encode(self).write(to: sidecarURL, options: .atomic)
    }

    /// Reads the sidecar for a clip. `url` may be either the `.mov` or the `.json`.
    static func load(url: URL) throws -> RecordedClip {
        let json = url.pathExtension.lowercased() == "json"
            ? url
            : url.deletingPathExtension().appendingPathExtension("json")
        return try decoder.decode(RecordedClip.self, from: Data(contentsOf: json))
    }

    /// Every clip in the recordings folder that still has both its files, newest first.
    static func loadAll() -> [RecordedClip] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: recordingsDirectory, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { try? load(url: $0) }
            .filter(\.fileExists)
            .sorted { $0.recordedAt > $1.recordedAt }
    }

    /// Removes the movie and its sidecar. Best effort: a missing file is not an error.
    func delete() {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: sidecarURL)
    }

    // MARK: - Reading the truth back out of the finished file

    /// Re-reads the written file and returns what it really is. Called once, after the recording stops,
    /// so the sidecar carries measured numbers and not just requested ones.
    ///
    /// `nominalFrameRate` is the track's own idea of its rate; `frames ÷ duration` is counted from the
    /// sample table. When the two disagree by more than a frame or so the clip dropped frames — on an
    /// iPhone that is nearly always the thermal governor quietly stepping the sensor down, which is
    /// exactly the failure the filming protocol warns about.
    static func measure(url: URL) async -> (nominal: Double?, average: Double?, duration: Double?, size: CGSize?) {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            return (nil, nil, nil, nil)
        }
        let nominal = try? await track.load(.nominalFrameRate)
        let size = try? await track.load(.naturalSize)
        let duration = try? await asset.load(.duration)
        let seconds = duration.map(CMTimeGetSeconds).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }

        var average: Double?
        if let seconds, let reader = try? AVAssetReader(asset: asset) {
            // Counting samples is the only way to catch a file that claims 240 fps and holds 190.
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                if reader.startReading() {
                    var frames = 0
                    while let buffer = output.copyNextSampleBuffer() {
                        if CMSampleBufferGetNumSamples(buffer) > 0 { frames += CMSampleBufferGetNumSamples(buffer) }
                    }
                    reader.cancelReading()
                    if frames > 1 { average = Double(frames) / seconds }
                }
            }
        }

        return (nominal.map(Double.init), average, seconds, size)
    }

    /// The hardware identifier, e.g. "iPhone15,2". `UIDevice.model` only ever says "iPhone".
    static var currentDeviceModel: String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw -> String in
            let bytes = raw.prefix(while: { $0 != 0 })
            return String(decoding: bytes, as: UTF8.self)
        }
        return machine.isEmpty ? "unknown" : machine
    }

    // MARK: - For the UI

    /// "1920×1080 · 240 fps · hFOV 47.9°"
    var summaryLine: String {
        let fps = measuredNominalFrameRate ?? requestedFrameRate
        return "\(pixelWidth)×\(pixelHeight) · \(Int(fps.rounded())) fps · hFOV \(String(format: "%.1f", videoFieldOfViewDegrees))°"
    }

    /// The factor the old import flow made the shooter type. Here it is a fact, not a guess: a clip
    /// recorded at 240 fps and played at 30 is 8× slow. Kept so the analysis path can be handed a number
    /// in the units it already speaks.
    var slowMotionFactorAgainst30fps: Double {
        (measuredNominalFrameRate ?? requestedFrameRate) / 30.0
    }
}
