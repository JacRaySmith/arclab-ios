import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Observation
import QuartzCore

// MARK: - What the session decided

/// An immutable description of the format the session is actually running, handed from the session
/// queue to the main actor. Every number here comes from `AVCaptureDevice.Format`; none is assumed.
struct CaptureConfiguration: Sendable, Equatable {
    var frameRate: Double
    /// Horizontal field of view in degrees, from the *active* format. HFR formats are cropped, so this
    /// is the only honest source for the lens angle — it is not the camera's photo-mode field of view.
    var fieldOfViewDegrees: Double
    var width: Int
    var height: Int
    var codec: String
    var warnings: [String]

    /// "1920×1080 · 240 fps · hFOV 47.9°"
    var line: String {
        "\(width)×\(height) · \(Int(frameRate.rounded())) fps · hFOV \(String(format: "%.1f", fieldOfViewDegrees))°"
    }
}

/// Everything the engine tells the main actor. All payloads are `Sendable` value types — no
/// `AVCapture…` object and no `Error` ever crosses the boundary.
enum CaptureEvent: Sendable {
    case unavailable(String)
    case failed(String)
    case configured(CaptureConfiguration)
    case running(Bool)
    case locks(focus: Bool, exposure: Bool, note: String)
    case recordingStarted
    /// `error` is `nil` on success. Only a description crosses the boundary, never the `Error`.
    case recordingFinished(url: URL, configuration: CaptureConfiguration, focusLocked: Bool, exposureLocked: Bool, error: String?)
    /// `nil` = the indicator could not run on this pixel format.
    case rimIndicator(Bool?)
    /// `AVCaptureSessionRuntimeError`. The session has stopped and the preview is black until something
    /// restarts it; `restartAttempt` says which try this is (0 = the error itself, not yet retried).
    case runtimeError(message: String, code: Int, restartAttempt: Int, recovered: Bool)
    /// `AVCaptureSessionWasInterrupted` — the camera was taken away (another app, a phone call, the
    /// screen being shared, the phone being too hot). `reason` is `AVCaptureSession.InterruptionReason`.
    case interrupted(reason: String, code: Int)
    case interruptionEnded
}

/// The interruption reasons by name, because the raw `Int` in the notification means nothing in a log.
private func interruptionReasonName(_ code: Int) -> String {
    switch AVCaptureSession.InterruptionReason(rawValue: code) {
    case .videoDeviceNotAvailableInBackground: return "videoDeviceNotAvailableInBackground"
    case .audioDeviceInUseByAnotherClient: return "audioDeviceInUseByAnotherClient"
    case .videoDeviceInUseByAnotherClient: return "videoDeviceInUseByAnotherClient"
    case .videoDeviceNotAvailableWithMultipleForegroundApps: return "videoDeviceNotAvailableWithMultipleForegroundApps"
    case .videoDeviceNotAvailableDueToSystemPressure: return "videoDeviceNotAvailableDueToSystemPressure"
    case .sensitiveContentMitigationActivated: return "sensitiveContentMitigationActivated"
    default: return "unknown(\(code))"
    }
}

/// What the shooter is told when the camera is taken away. Never a blank screen with no explanation.
private func interruptionSentence(_ code: Int) -> String {
    switch AVCaptureSession.InterruptionReason(rawValue: code) {
    case .videoDeviceNotAvailableInBackground:
        return "The camera stopped because ArcLab left the screen. Come back to this screen and it starts again."
    case .audioDeviceInUseByAnotherClient:
        return "Another app or the spoken feedback took the microphone, so the camera stopped. It starts again by itself when the audio is free."
    case .videoDeviceInUseByAnotherClient:
        return "Another app is using the camera. Close it and come back to this screen."
    case .videoDeviceNotAvailableWithMultipleForegroundApps:
        return "iOS will not give the camera to an app sharing the screen. Leave Split View or Slide Over and come back."
    case .videoDeviceNotAvailableDueToSystemPressure:
        return "The camera stopped because the phone is under too much system pressure — nearly always heat. Let it cool and come back."
    default:
        return "The camera was interrupted by iOS (\(interruptionReasonName(code))) and has stopped."
    }
}

// MARK: - The session (off the main actor)

/// Owns the `AVCaptureSession` and touches it only on `sessionQueue`. Marked `@unchecked Sendable`
/// because that invariant is enforced by this file, not by the compiler: every mutable property below
/// is read and written on `sessionQueue` alone, and the one exception (`session`, which the preview
/// layer needs on the main thread) is documented where it is declared.
final class CaptureEngine: NSObject, @unchecked Sendable {
    /// The one queue all session and device configuration happens on. `AVCaptureSession.startRunning()`
    /// blocks, so it must never be the main queue.
    let sessionQueue = DispatchQueue(label: "com.arclab.capture.session", qos: .userInitiated)

    /// Read by `AVCaptureVideoPreviewLayer` on the main thread. `AVCaptureSession` is documented as safe
    /// to hand to a preview layer from another thread; nothing else on the main actor touches it.
    nonisolated(unsafe) let session = AVCaptureSession()

    private let emit: @Sendable (CaptureEvent) -> Void

    private var device: AVCaptureDevice?
    private var movieOutput: AVCaptureMovieFileOutput?
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var configuration: CaptureConfiguration?
    private var focusLocked = false
    private var exposureLocked = false
    private var isConfigured = false
    /// Bumped by every lock request so a stale settle-then-lock callback is ignored.
    private var lockGeneration = 0
    private var isRecording = false

    // Rim indicator state, session queue only.
    private let sampleQueue = DispatchQueue(label: "com.arclab.capture.samples", qos: .utility)
    private var lastRimCheck: CFTimeInterval = 0
    private var captureRotationIsFlipped = false

    /// `AVCaptureSession`'s notifications. Kept so they can be removed in `teardown` — this object is
    /// created afresh every time the record screen is pushed, and a leaked observer would outlive it.
    private var notificationTokens: [any NSObjectProtocol] = []
    /// How many times a runtime error has been recovered from in this session's life. Capped, because
    /// a session that will not come back must say so rather than spin restarting for ever.
    private var restartAttempts = 0
    private static let maxRestartAttempts = 3
    private var isTornDown = false

    init(emit: @escaping @Sendable (CaptureEvent) -> Void) {
        self.emit = emit
        super.init()
    }

    // MARK: Configure

    /// Builds the session: back **wide (1×)** camera, 1080p at the highest rate ≥ 120, HEVC, audio on.
    func configure() {
        sessionQueue.async { [self] in
            guard !isConfigured else { return }

            // The physical wide-angle camera only. Never `.builtInDualWideCamera` or `.builtInTripleCamera`:
            // a virtual device switches to the ultra-wide or the telephoto on its own, and the lens
            // geometry is part of the calibration. Never the ultra-wide or telephoto directly either.
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .back)
            guard let camera = discovery.devices.first else {
                emit(.unavailable("No back camera. The Simulator has none — record on the iPhone."))
                return
            }
            device = camera

            session.beginConfiguration()
            // `.inputPriority` means the session will not override the format we are about to choose.
            session.sessionPreset = .inputPriority

            do {
                let videoInput = try AVCaptureDeviceInput(device: camera)
                guard session.canAddInput(videoInput) else {
                    session.commitConfiguration()
                    emit(.failed("The camera input could not be added to the session."))
                    return
                }
                session.addInput(videoInput)
            } catch {
                session.commitConfiguration()
                emit(.failed("The camera could not be opened: \(error.localizedDescription)"))
                return
            }

            // Audio: the protocol asks the shooter to say "make" or "miss" after every shot. The audio
            // track *is* the ground-truth log, so a clip without it is worth less.
            var warnings: [String] = []
            if let mic = AVCaptureDevice.default(for: .audio),
               let audioInput = try? AVCaptureDeviceInput(device: mic),
               session.canAddInput(audioInput) {
                session.addInput(audioInput)
            } else {
                warnings.append("No audio track: the spoken make/miss log was not recorded.")
            }

            let movie = AVCaptureMovieFileOutput()
            guard session.canAddOutput(movie) else {
                session.commitConfiguration()
                emit(.failed("The movie output could not be added to the session."))
                return
            }
            session.addOutput(movie)
            movieOutput = movie

            // Format. 1080p, highest frame rate ≥ 120 (240 preferred).
            guard let choice = CaptureEngine.chooseFormat(for: camera) else {
                session.commitConfiguration()
                emit(.failed("This camera offers no 1920×1080 video format."))
                return
            }
            if choice.frameRate < 120 {
                warnings.append(String(format:
                    "Only %.0f fps is available at 1080p on this camera. The release instant is found to a frame, so the release angle is coarser than the protocol assumes.",
                    choice.frameRate))
            }

            do {
                try camera.lockForConfiguration()
                camera.activeFormat = choice.format

                // Auto frame rate (iOS 18+) silently trades frame rate for exposure in a dim gym. The
                // whole time base depends on the rate being what we say it is, so it goes off *before*
                // the frame duration is pinned — setting a locked duration throws while it is on.
                if choice.format.isAutoVideoFrameRateSupported, camera.isAutoVideoFrameRateEnabled {
                    camera.isAutoVideoFrameRateEnabled = false
                }
                let duration = CMTime(value: 1, timescale: CMTimeScale(choice.frameRate.rounded()))
                camera.activeVideoMinFrameDuration = duration
                camera.activeVideoMaxFrameDuration = duration

                // 1× and nothing else. No digital zoom, no ramp.
                camera.videoZoomFactor = 1.0

                if camera.hasTorch, camera.isTorchModeSupported(.off) { camera.torchMode = .off }
                // Low-light boost halves the frame rate when it engages.
                if camera.isLowLightBoostSupported { camera.automaticallyEnablesLowLightBoostWhenAvailable = false }
                // Nothing may re-trigger autofocus once the shooter has locked it.
                camera.isSubjectAreaChangeMonitoringEnabled = false
                camera.automaticallyAdjustsVideoHDREnabled = false
                if camera.activeFormat.isVideoHDRSupported { camera.isVideoHDREnabled = false }

                camera.unlockForConfiguration()
            } catch {
                session.commitConfiguration()
                emit(.failed("The camera format could not be set: \(error.localizedDescription)"))
                return
            }

            // Codec + connection settings.
            var codec = "h264"
            if let connection = movie.connection(with: .video) {
                if movie.availableVideoCodecTypes.contains(.hevc) {
                    movie.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
                    codec = "hevc"
                }
                // Stabilisation warps and shifts the image frame by frame. The entire geometry assumes a
                // camera that does not move, so it must be off — a tripod is the protocol's answer instead.
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .off
                }
            }

            // An orange-blob framing aid, if the session will take a second output. Processing is capped
            // at 5 Hz and skipped entirely while recording, so it costs nothing on the recording path.
            let data = AVCaptureVideoDataOutput()
            data.alwaysDiscardsLateVideoFrames = true
            data.videoSettings = [:]  // device-native pixel format: no conversion, no rotation pipeline
            if session.canAddOutput(data) {
                session.addOutput(data)
                data.setSampleBufferDelegate(self, queue: sampleQueue)
                videoDataOutput = data
            }

            session.commitConfiguration()

            let config = CaptureConfiguration(
                frameRate: choice.frameRate,
                fieldOfViewDegrees: Double(choice.format.videoFieldOfView),
                width: choice.width,
                height: choice.height,
                codec: codec,
                warnings: warnings)
            configuration = config
            isConfigured = true
            observeSessionHealth()
            emit(.configured(config))
        }
    }

    // MARK: Is the session still alive?

    /// The four notifications an `AVCaptureSession` uses to say it has stopped, and why. Without these
    /// the app cannot tell a running camera from a dead one: the preview layer simply stays black,
    /// `isRunning` keeps whatever it was last told, and the record button stays armed over nothing.
    /// That is the failure the 2026-09-18 log could not explain, because none of it was ever recorded.
    ///
    /// `queue: nil` means the block runs on the thread that posted it; every value is pulled out of the
    /// `Notification` there and only `Sendable` scalars cross into `emit`.
    private func observeSessionHealth() {
        guard notificationTokens.isEmpty else { return }
        let center = NotificationCenter.default
        let emit = self.emit
        notificationTokens.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self?.recoverFromRuntimeError(message: error?.localizedDescription ?? "no error description",
                                          code: error?.code ?? 0)
        })
        notificationTokens.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil
        ) { note in
            let code = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int) ?? -1
            emit(.interrupted(reason: interruptionReasonName(code), code: code))
        })
        notificationTokens.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil
        ) { [weak self] _ in
            emit(.interruptionEnded)
            // iOS restarts the session itself after most interruptions, but not all of them; asking
            // again costs nothing when it is already running (`start` is guarded).
            self?.start()
        })
        notificationTokens.append(center.addObserver(
            forName: AVCaptureSession.didStartRunningNotification, object: session, queue: nil
        ) { _ in emit(.running(true)) })
        notificationTokens.append(center.addObserver(
            forName: AVCaptureSession.didStopRunningNotification, object: session, queue: nil
        ) { _ in emit(.running(false)) })
    }

    /// A media-services reset (`AVError.mediaServicesWereReset`, −11819) kills the session and blanks
    /// the preview. Apple's documented answer is to start it again; anything else that stops the
    /// session gets the same treatment, capped so a camera that is truly gone is reported rather than
    /// retried for ever.
    private func recoverFromRuntimeError(message: String, code: Int) {
        sessionQueue.async { [self] in
            guard !isTornDown else { return }
            guard restartAttempts < Self.maxRestartAttempts else {
                emit(.runtimeError(message: message, code: code, restartAttempt: restartAttempts, recovered: false))
                return
            }
            restartAttempts += 1
            let attempt = restartAttempts
            if !session.isRunning { session.startRunning() }
            let running = session.isRunning
            emit(.runtimeError(message: message, code: code, restartAttempt: attempt, recovered: running))
            if running { scheduleAutoLock() }
        }
    }

    /// 1080p, highest frame rate ≥ 120. Ties (the same rate from several formats) break on the widest
    /// field of view, so the shooter gets as much of the arc in frame as the hardware allows.
    static func chooseFormat(for device: AVCaptureDevice) -> (format: AVCaptureDevice.Format, frameRate: Double, width: Int, height: Int)? {
        var best: (format: AVCaptureDevice.Format, frameRate: Double, width: Int, height: Int)?
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.width == 1920, dims.height == 1080 else { continue }
            guard let rate = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() else { continue }
            let candidate = (format, rate, Int(dims.width), Int(dims.height))
            guard let current = best else { best = candidate; continue }
            if rate > current.frameRate + 0.5 {
                best = candidate
            } else if abs(rate - current.frameRate) <= 0.5,
                      format.videoFieldOfView > current.format.videoFieldOfView {
                best = candidate
            }
        }
        return best
    }

    // MARK: Run

    func start() {
        sessionQueue.async { [self] in
            guard isConfigured, !session.isRunning else { return }
            session.startRunning()
            emit(.running(session.isRunning))
            // Nobody tapped: lock on the centre of the frame after 2 s so a clip is never filmed with
            // the exposure still hunting.
            scheduleAutoLock()
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if let movie = movieOutput, movie.isRecording { movie.stopRecording() }
            guard session.isRunning else { return }
            session.stopRunning()
            emit(.running(false))
        }
    }

    /// Stop *and* let go. `AVCaptureVideoDataOutput` holds its sample-buffer delegate `unowned(unsafe)`,
    /// so an engine that is deallocated while a frame is being handed to it is a use-after-free — and
    /// this engine is built and thrown away every single time the record screen is pushed and popped.
    /// `stop()` alone was not enough: `stopRunning()` returns while a callback can still be running on
    /// `sampleQueue`.
    ///
    /// So: drop the delegate first (after that no new callback can start), then drain `sampleQueue`
    /// with a `sync` barrier (after that no callback is still running), and only then let the strong
    /// `self` this block captured go. The notification observers go with it.
    func teardown() {
        sessionQueue.async { [self] in
            isTornDown = true
            videoDataOutput?.setSampleBufferDelegate(nil, queue: nil)
            for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
            notificationTokens = []
            if let movie = movieOutput, movie.isRecording { movie.stopRecording() }
            if session.isRunning { session.stopRunning() }
            // `sampleQueue` never waits on `sessionQueue`, so this cannot deadlock. It is the point at
            // which no `captureOutput` is in flight any more.
            sampleQueue.sync {}
        }
    }

    // MARK: Focus / exposure lock

    /// `point` is in the camera's own coordinates (0…1, from `captureDevicePointConverted`).
    func lock(atDevicePoint point: CGPoint) {
        sessionQueue.async { [self] in
            guard let camera = device else { return }
            lockGeneration += 1
            let generation = lockGeneration
            do {
                try camera.lockForConfiguration()
                if camera.isFocusPointOfInterestSupported { camera.focusPointOfInterest = point }
                if camera.isFocusModeSupported(.autoFocus) { camera.focusMode = .autoFocus }
                if camera.isExposurePointOfInterestSupported { camera.exposurePointOfInterest = point }
                if camera.isExposureModeSupported(.autoExpose) { camera.exposureMode = .autoExpose }
                camera.unlockForConfiguration()
            } catch {
                emit(.locks(focus: focusLocked, exposure: exposureLocked,
                            note: "Focus could not be set: \(error.localizedDescription)"))
                return
            }
            emit(.locks(focus: false, exposure: false, note: "Focusing…"))
            // Let the lens and the exposure settle on the tapped point, then freeze them.
            sessionQueue.asyncAfter(deadline: .now() + 0.9) { [self] in
                guard generation == lockGeneration else { return }
                engageLocks()
            }
        }
    }

    private func scheduleAutoLock() {
        lockGeneration += 1
        let generation = lockGeneration
        sessionQueue.asyncAfter(deadline: .now() + 2.0) { [self] in
            guard generation == lockGeneration, !focusLocked else { return }
            engageLocks()
        }
    }

    private func engageLocks() {
        guard let camera = device else { return }
        do {
            try camera.lockForConfiguration()
            if camera.isFocusModeSupported(.locked) { camera.focusMode = .locked; focusLocked = true }
            if camera.isExposureModeSupported(.locked) { camera.exposureMode = .locked; exposureLocked = true }
            // White balance too: the rim indicator and the ball detector both key on colour.
            if camera.isWhiteBalanceModeSupported(.locked) { camera.whiteBalanceMode = .locked }
            camera.unlockForConfiguration()
        } catch {
            emit(.locks(focus: focusLocked, exposure: exposureLocked,
                        note: "Could not lock: \(error.localizedDescription)"))
            return
        }
        let note: String
        switch (focusLocked, exposureLocked) {
        case (true, true): note = "Focus and exposure locked."
        case (true, false): note = "Focus locked; this camera will not lock exposure."
        case (false, true): note = "Exposure locked; this camera will not lock focus."
        case (false, false): note = "This camera supports neither lock."
        }
        emit(.locks(focus: focusLocked, exposure: exposureLocked, note: note))
    }

    // MARK: Rotation

    /// Applied to the movie connection so the file is written horizon-level, and used to work out which
    /// end of the raw buffer is the top of the picture for the rim indicator.
    func setCaptureRotationAngle(_ angle: CGFloat) {
        sessionQueue.async { [self] in
            captureRotationIsFlipped = abs(angle - 180) < 1
            guard let connection = movieOutput?.connection(with: .video),
                  connection.isVideoRotationAngleSupported(angle) else { return }
            connection.videoRotationAngle = angle
        }
    }

    // MARK: Record

    func startRecording(to url: URL) {
        sessionQueue.async { [self] in
            guard let movie = movieOutput, session.isRunning, !movie.isRecording else { return }
            isRecording = true
            movie.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stopRecording() {
        sessionQueue.async { [self] in
            guard let movie = movieOutput, movie.isRecording else { return }
            movie.stopRecording()
        }
    }
}

// MARK: - Recording delegate

extension CaptureEngine: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                               from connections: [AVCaptureConnection]) {
        emit(.recordingStarted)
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                               from connections: [AVCaptureConnection], error: (any Error)?) {
        // A stop always "errors" with AVErrorRecordingSuccessfullyFinished-style userInfo when the file
        // is fine; only a genuine failure is reported up. The `Error` itself never crosses the boundary.
        let message: String? = {
            guard let error else { return nil }
            let ns = error as NSError
            let finishedFine = (ns.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) ?? false
            return finishedFine ? nil : error.localizedDescription
        }()
        sessionQueue.async { [self] in
            isRecording = false
            let config = configuration ?? CaptureConfiguration(
                frameRate: 0, fieldOfViewDegrees: 0, width: 0, height: 0, codec: "unknown", warnings: [])
            emit(.recordingFinished(url: outputFileURL, configuration: config,
                                    focusLocked: focusLocked, exposureLocked: exposureLocked,
                                    error: message))
        }
    }
}

// MARK: - Rim-in-frame indicator

extension CaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
    /// A coarse "is there orange in the top third" check, ≤ 5 Hz, on the chroma plane of the native
    /// 4:2:0 buffer — no colour conversion, no CIFilter, no GPU work. Skipped entirely while recording so
    /// it can never cost the 240 fps file a frame. It is a *framing aid*, not a measurement: a wooden
    /// floor, a ball rack or a sunset also read as orange.
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        // `isRecording` and `lastRimCheck` are touched on `sampleQueue` here and on `sessionQueue`
        // elsewhere; `sampleQueue` reads a stale `isRecording` at worst, which costs one skipped frame.
        guard !isRecording else { return }
        let now = CACurrentMediaTime()
        guard now - lastRimCheck >= 0.2 else { return }
        lastRimCheck = now

        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let result = CaptureEngine.orangeInTopThird(of: pixels, flipped: captureRotationIsFlipped)
        emit(.rimIndicator(result))
    }

    /// `nil` when the buffer is not a biplanar 4:2:0 format this can read.
    static func orangeInTopThird(of pixels: CVPixelBuffer, flipped: Bool) -> Bool? {
        let format = CVPixelBufferGetPixelFormatType(pixels)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else { return nil }

        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 1) else { return nil }

        let width = CVPixelBufferGetWidthOfPlane(pixels, 1)     // chroma: half the luma width
        let height = CVPixelBufferGetHeightOfPlane(pixels, 1)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixels, 1)
        guard width > 8, height > 8 else { return nil }

        // The native buffer is unrotated. In one of the two landscape orientations the picture's top is
        // the buffer's first rows; in the other it is the last.
        let band = height / 3
        let firstRow = flipped ? height - band : 0
        let lastRow = flipped ? height : band

        // Basketball orange (≈ RGB 204,85,40) sits at Cr ≈ 190, Cb ≈ 85 in Rec.601 chroma.
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var orange = 0
        var row = firstRow
        while row < lastRow {
            let line = bytes + row * rowBytes
            var x = 0
            while x < width {
                let cb = line[x * 2]
                let cr = line[x * 2 + 1]
                if cr >= 150, cb <= 115 { orange += 1 }
                x += 2
            }
            row += 2
        }
        // A 45.7 cm rim filmed from 7–9 m is a few hundred luma pixels of orange; this sampling sees
        // roughly a thirtieth of them. Twelve is well above the noise of a wooden floor in the top third.
        return orange >= 12
    }
}

// MARK: - The main-actor face of the camera

/// UI state for the recording screen. Every property here is main-actor; every `AVCapture…` object
/// lives inside `CaptureEngine` on its own queue.
@MainActor
@Observable
final class CaptureController {
    enum Permission: Sendable { case unknown, authorized, denied, restricted }

    enum Status: Equatable {
        case idle
        case configuring
        case ready
        case recording
        case saving
        /// The device cannot do this at all (the Simulator, or no back camera).
        case unavailable(String)
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var cameraPermission: Permission = .unknown
    private(set) var microphonePermission: Permission = .unknown
    private(set) var configuration: CaptureConfiguration?
    private(set) var focusLocked = false
    private(set) var exposureLocked = false
    private(set) var lockNote = "Focus and exposure lock 2 s after this screen opens, or tap the shooter."
    private(set) var isRunning = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var rimInFrame: Bool?
    private(set) var lastClip: RecordedClip?
    private(set) var thermalWarning: String?
    /// Set when the session stopped for a reason iOS told us about — an interruption or a runtime
    /// error. A black preview always has a sentence next to it now, never nothing.
    private(set) var healthNote: String?
    /// True while `AVCaptureSession` says it is interrupted; cleared by `interruptionEnded`.
    private(set) var isInterrupted = false

    /// Where the picture actually is inside the preview view, in that view's own coordinates. Read
    /// from `AVCaptureVideoPreviewLayer` itself (`layerRectConverted`), which is the only thing that
    /// knows the layer's bounds, its `.resizeAspect` gravity *and* the rotation applied to its
    /// connection all at once. The framing overlay is drawn against this and nothing else.
    private(set) var previewVideoRect: CGRect = .zero
    /// The rotation the preview connection is currently showing, degrees. 0/180 = the picture is the
    /// sensor's landscape frame; 90/270 = it has been turned upright and is taller than it is wide.
    private(set) var previewRotationDegrees: CGFloat = 0
    /// The rotation the *movie* connection was last told to apply, degrees
    /// (`videoRotationAngleForHorizonLevelCapture`). Kept because the gravity measured while filming
    /// means nothing without knowing which way the picture was turned when it was written.
    private(set) var captureRotationDegrees: CGFloat = 0
    /// The capture rotation as it stood when the current recording started, and whether it has moved
    /// since. A phone turned over mid-clip has no single frame to express gravity in, and that is a
    /// reason to withhold the measurement, not to pick one of the two.
    private var rotationAtRecordingStart: CGFloat?
    private var rotationChangedWhileRecording = false

    /// Called on the main actor once a clip is on disk with its sidecar written.
    var onRecorded: ((RecordedClip) -> Void)?

    private var engine: CaptureEngine?
    private var recordingID: UUID?
    private var recordingStart: Date?
    private var tickTask: Task<Void, Never>?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservations: [NSKeyValueObservation] = []
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    /// Removed in `end()`. `begin()` runs on every appearance of the record screen, and the old code
    /// added one of these each time and removed none.
    private var thermalObserver: (any NSObjectProtocol)?

    var session: AVCaptureSession? { engine?.session }

    var isRecording: Bool { if case .recording = status { return true }; return false }

    var canRecord: Bool {
        guard case .ready = status else { return false }
        return isRunning
    }

    // MARK: Lifecycle

    /// Asks for permission, then configures and starts the session. Safe to call again on every appear.
    func begin() async {
        #if targetEnvironment(simulator)
        status = .unavailable("The Simulator has no camera. Run ArcLab on the iPhone to record; on the Simulator, import a clip instead.")
        return
        #else
        if case .unavailable = status { return }

        cameraPermission = await CaptureController.request(.video)
        guard cameraPermission == .authorized else {
            status = .idle
            return
        }
        microphonePermission = await CaptureController.request(.audio)

        if engine == nil {
            let created = CaptureEngine { [weak self] event in
                Task { @MainActor [weak self] in self?.handle(event) }
            }
            engine = created
            status = .configuring
            created.configure()
        }
        engine?.start()
        observeThermalState()
        // Warm the motion sensors up with the camera: device motion takes a moment to settle, and
        // the first sample must not be the one that is still converging.
        GravitySampler.shared.start()
        #endif
    }

    /// Stops the session *and* releases every hook into it. Call from `.onDisappear`: a running
    /// capture session is the most expensive thing the app can leave switched on, and an engine that
    /// is still a sample-buffer delegate when it deallocates is a crash.
    func end() {
        ActivityLog.shared.event("capture.end", ["wasRunning": isRunning, "recording": isRecording])
        tickTask?.cancel()
        tickTask = nil
        rotationObservations = []
        rotationCoordinator = nil
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
        thermalObserver = nil
        engine?.teardown()
        engine = nil
        isRunning = false
        GravitySampler.shared.stop()
    }

    private static func request(_ media: AVMediaType) async -> Permission {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: media) ? .authorized : .denied
        @unknown default: return .denied
        }
    }

    // MARK: Events from the engine

    private func handle(_ event: CaptureEvent) {
        switch event {
        case .unavailable(let message):
            status = .unavailable(message)
            ActivityLog.shared.event("capture.unavailable", ["message": message])
        case .failed(let message):
            status = .failed(message)
            ActivityLog.shared.event("capture.failed", ["message": message])
        case .configured(let config):
            configuration = config
            if case .failed = status {} else { status = .ready }
            // The format the session actually chose. A clip that comes back at the wrong frame rate,
            // or a screen that will not record, is explained by this line and nothing else.
            ActivityLog.shared.event("capture.configured", [
                "width": config.width, "height": config.height, "fps": config.frameRate,
                "hfov": config.fieldOfViewDegrees, "codec": config.codec,
                "warnings": config.warnings.joined(separator: " | "),
                "thermal": ActivityLog.thermal()])
            refreshPreviewRect()
        case .running(let running):
            let changed = running != isRunning
            isRunning = running
            if running {
                isInterrupted = false
                healthNote = nil
                // A session that is running again is usable again. Without this a recovered runtime
                // error left `status` stuck on `.failed`, which disables the record button for ever.
                switch status {
                case .configuring, .failed: if configuration != nil { status = .ready }
                default: break
                }
            }
            if changed { ActivityLog.shared.event("capture.running", ["running": running, "thermal": ActivityLog.thermal()]) }
        case .runtimeError(let message, let code, let attempt, let recovered):
            ActivityLog.shared.event("capture.runtimeError", ["message": message, "code": code,
                                                              "restartAttempt": attempt, "recovered": recovered,
                                                              "thermal": ActivityLog.thermal()])
            if recovered {
                healthNote = "The camera stopped (\(message)) and was started again."
            } else {
                healthNote = "The camera stopped and could not be started again: \(message). Leave this screen and come back, or reopen ArcLab."
                isRunning = false
                status = .failed(healthNote ?? message)
            }
        case .interrupted(let reason, let code):
            isInterrupted = true
            isRunning = false
            healthNote = interruptionSentence(code)
            ActivityLog.shared.event("capture.interrupted", ["reason": reason, "code": code,
                                                             "recording": isRecording, "thermal": ActivityLog.thermal()])
        case .interruptionEnded:
            isInterrupted = false
            healthNote = nil
            ActivityLog.shared.event("capture.interruptionEnded")
        case .locks(let focus, let exposure, let note):
            focusLocked = focus
            exposureLocked = exposure
            lockNote = note
        case .recordingStarted:
            recordingStart = Date()
            status = .recording
            // From here until the file is written, every tick adds a gravity sample. This is the
            // only moment the phone is definitely pointing where the clip was filmed from.
            rotationAtRecordingStart = captureRotationDegrees
            rotationChangedWhileRecording = false
            GravitySampler.shared.beginCollecting()
            startTicking()
        case .recordingFinished(let url, let config, let focus, let exposure, let error):
            finishRecording(url: url, config: config, focusLocked: focus, exposureLocked: exposure, error: error)
        case .rimIndicator(let seen):
            rimInFrame = seen
        }
    }

    // MARK: Preview + rotation

    /// Handed the preview layer by `CaptureView` once it exists, so the rotation coordinator can keep
    /// both the preview and the written file horizon-level.
    func attach(previewLayer layer: AVCaptureVideoPreviewLayer) {
        // A *different* layer means the preview view was rebuilt (a rotation, a re-presented cover, a
        // change of view identity). The old coordinator was bound to the layer that has gone, so it
        // would go on reporting angles for a view nobody can see. Rebind it, never keep the old one.
        let isNewLayer = previewLayer !== layer
        previewLayer = layer
        guard isNewLayer || rotationCoordinator == nil else { refreshPreviewRect(); return }
        rotationObservations = []
        rotationCoordinator = nil
        guard let camera = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .back).devices.first
        else { refreshPreviewRect(); return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: camera, previewLayer: layer)
        rotationCoordinator = coordinator
        applyRotation()
        // KVO updates are delivered on the main queue by the coordinator, per its documentation.
        rotationObservations = [
            coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.applyRotation() }
            },
            coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.applyRotation() }
            },
        ]
    }

    private func applyRotation() {
        guard let coordinator = rotationCoordinator else { return }
        let previewAngle = coordinator.videoRotationAngleForHorizonLevelPreview
        if let connection = previewLayer?.connection, connection.isVideoRotationAngleSupported(previewAngle) {
            connection.videoRotationAngle = previewAngle
        }
        previewRotationDegrees = previewAngle
        let captureAngle = coordinator.videoRotationAngleForHorizonLevelCapture
        if let atStart = rotationAtRecordingStart, abs(captureAngle - atStart) > 0.5 {
            rotationChangedWhileRecording = true
        }
        captureRotationDegrees = captureAngle
        engine?.setCaptureRotationAngle(captureAngle)
        // A rotation changes where the picture is without changing the view's bounds, so `layoutSubviews`
        // never fires for it. This is the only thing that tells the overlay the frame moved.
        refreshPreviewRect()
    }

    /// Called by the preview view whenever its bounds change (every rotation, every safe-area change),
    /// and by `applyRotation`.
    func previewGeometryChanged() { refreshPreviewRect() }

    private func refreshPreviewRect() {
        guard let layer = previewLayer else { return }
        let bounds = layer.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }
        // What the layer itself says: the whole video frame (metadata rect 0,0,1,1) mapped into layer
        // coordinates, through `.resizeAspect` and the connection's rotation.
        let reported = layer.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
        let finite = reported.origin.x.isFinite && reported.origin.y.isFinite
            && reported.size.width.isFinite && reported.size.height.isFinite
        let usable = finite && !reported.isEmpty
            && reported.width <= bounds.width + 1 && reported.height <= bounds.height + 1
        let rect: CGRect
        if usable {
            rect = reported
        } else if let configuration {
            // Before the session has a connection the layer has nothing to convert. Fall back to the
            // same arithmetic against the format's own dimensions, rotated the way the preview is.
            rect = CaptureView.videoRect(in: bounds.size, sourceWidth: configuration.width,
                                         sourceHeight: configuration.height,
                                         rotationDegrees: previewRotationDegrees)
        } else {
            rect = .zero
        }
        guard rect != previewVideoRect else { return }
        previewVideoRect = rect
    }

    /// `point` is in the preview layer's coordinates; converted here to the camera's own.
    func lockFocusAndExposure(atPreviewPoint point: CGPoint) {
        guard let layer = previewLayer, let engine else { return }
        engine.lock(atDevicePoint: layer.captureDevicePointConverted(fromLayerPoint: point))
    }

    // MARK: Record

    func startRecording() {
        ActivityLog.shared.event("capture.record.start")
        startRecordingImpl()
    }
    private func startRecordingImpl() {
        guard canRecord, let engine else { return }
        let id = UUID()
        recordingID = id
        elapsed = 0
        engine.startRecording(to: RecordedClip.newMovieURL(id: id))
    }

    func stopRecording() {
        ActivityLog.shared.event("capture.record.stop")
        stopRecordingImpl()
    }
    private func stopRecordingImpl() {
        guard isRecording else { return }
        status = .saving
        tickTask?.cancel()
        tickTask = nil
        engine?.stopRecording()
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let start = self.recordingStart else { return }
                self.elapsed = Date().timeIntervalSince(start)
                GravitySampler.shared.sample()
            }
        }
    }

    private func finishRecording(url: URL, config: CaptureConfiguration,
                                 focusLocked: Bool, exposureLocked: Bool, error: String?) {
        tickTask?.cancel()
        tickTask = nil
        recordingStart = nil

        // Close the gravity collection before anything can fail, so a discarded clip does not leave
        // samples running into the next one.
        let gravity = GravitySampler.shared.finishCollecting()
        let rotationAtStart = rotationAtRecordingStart
        let rotationMoved = rotationChangedWhileRecording
        rotationAtRecordingStart = nil
        rotationChangedWhileRecording = false

        if let error {
            status = .failed("The recording failed: \(error)")
            try? FileManager.default.removeItem(at: url)
            return
        }

        status = .saving
        // The id is the file's own stem, not `recordingID`: if a second start slipped through before the
        // delegate confirmed the first, the clip and its sidecar must still agree with the file on disk.
        let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) ?? recordingID ?? UUID()
        recordingID = nil
        var warnings = config.warnings
        if !focusLocked { warnings.append("Focus was not locked: the ball's size on the sensor can drift mid-clip.") }
        if !exposureLocked { warnings.append("Exposure was not locked: brightness can change mid-clip.") }
        if let thermalWarning { warnings.append(thermalWarning) }

        Task { [weak self] in
            // Read the file back: the sidecar must carry what the file *is*, not what was asked for.
            let measured = await RecordedClip.measure(url: url)
            var clipWarnings = warnings
            if measured.nominal == nil {
                clipWarnings.append("The finished file could not be re-read, so its true frame rate is unknown.")
            } else if let nominal = measured.nominal, let average = measured.average,
                      abs(nominal - average) > max(2.0, nominal * 0.05) {
                clipWarnings.append(String(format:
                    "The file says %.0f fps but holds %.0f frames per second of it — frames were dropped, most likely the phone getting hot.",
                    nominal, average))
            }

            // Which way was down while this clip was filmed. A phone that was turned over mid-clip
            // has no one answer, so the measurement is dropped with the reason rather than averaged
            // across two orientations.
            var gravityMeasurement = gravity.measurement
            var gravityReason = gravity.unavailableReason
            if rotationMoved {
                gravityMeasurement = nil
                gravityReason = "the phone was turned over while it was filming, so this clip has no single direction of down"
            }

            let clip = RecordedClip(
                id: id,
                movieFileName: url.lastPathComponent,
                requestedFrameRate: config.frameRate,
                measuredNominalFrameRate: measured.nominal,
                measuredAverageFrameRate: measured.average,
                durationSeconds: measured.duration,
                videoFieldOfViewDegrees: config.fieldOfViewDegrees,
                pixelWidth: measured.size.map { Int($0.width.rounded()) } ?? config.width,
                pixelHeight: measured.size.map { Int($0.height.rounded()) } ?? config.height,
                videoCodec: config.codec,
                focusLocked: focusLocked,
                exposureLocked: exposureLocked,
                warnings: clipWarnings,
                gravityDevice: gravityMeasurement,
                gravityUnavailableReason: gravityReason,
                captureRotationDegrees: rotationAtStart.map(Double.init),
                storedTransformRotationDegrees: measured.transformRotationDegrees)

            ActivityLog.shared.event("capture.gravity", [
                "measured": gravityMeasurement != nil,
                "reason": gravityReason,
                "samples": gravityMeasurement?.samples,
                "spreadDeg": gravityMeasurement.map { ($0.spreadDegrees * 100).rounded() / 100 },
                "captureRotationDeg": rotationAtStart.map(Double.init),
                "transformRotationDeg": measured.transformRotationDegrees,
                "sensorToStoredDeg": clip.sensorToStoredRotationDegrees,
                "cameraUpUnavailable": clip.measuredUpUnavailableReason,
            ])

            await MainActor.run { [weak self] in
                guard let self else { return }
                do {
                    try clip.saveSidecar()
                } catch {
                    self.status = .failed("The clip was recorded but its sidecar could not be written: \(error.localizedDescription)")
                    return
                }
                self.lastClip = clip
                self.elapsed = 0
                self.status = .ready
                self.onRecorded?(clip)
            }
        }
    }

    // MARK: Thermal

    /// High frame rates run the phone hot, and a hot phone quietly drops the sensor's frame rate — the
    /// exact failure the filming protocol warns about. Say so while there is still time to stop.
    private func observeThermalState() {
        updateThermalWarning()
        guard thermalObserver == nil else { return }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateThermalWarning() }
        }
    }

    private func updateThermalWarning() {
        switch ProcessInfo.processInfo.thermalState {
        case .serious:
            thermalWarning = "The phone is hot. The frame rate can drop without warning — stop soon and let it cool."
        case .critical:
            thermalWarning = "The phone is too hot to film reliably. Stop and let it cool; the frame rate is probably already down."
        default:
            thermalWarning = nil
        }
    }
}
