import AppKit
import CoreVideo

/// One run of the extra display: virtual display -> capture -> H.264 -> viewers.
/// Create, start and stop it on the main thread.
final class Session {
    enum Failure: LocalizedError {
        case displayRefused
        case encoder(Error)
        case capture(Error)

        var errorDescription: String? {
            switch self {
            case .displayRefused:
                return "macOS refused to create the display."
            case .encoder(let error), .capture(let error):
                return error.localizedDescription
            }
        }
    }

    let geometry: DisplayGeometry
    let fps: Int
    let quality: VideoQuality
    private let server: StreamServer
    private let pipeline = DispatchQueue(label: "sidetab.pipeline", qos: .userInteractive)
    private var display: VirtualDisplay?
    private var capturer: ScreenCapturer?
    private var stopped = false

    // Only touched on `pipeline`.
    private var encoder: H264Encoder?
    private var lastFrame: CVPixelBuffer?
    private var keyframeWanted = true
    private var framesCaptured = 0
    private var framesSent = 0
    private var bytesSent = 0
    private var statsTimer: DispatchSourceTimer?
    // Android hardware decoders hold each frame until the next one arrives, so
    // after every change a few repeats of the last picture push it through.
    private var repeatTimer: DispatchSourceTimer?
    private var repeatsLeft = 0
    private var lastEncode = DispatchTime.now()

    var displayID: CGDirectDisplayID? { display?.displayID }

    init(geometry: DisplayGeometry, fps: Int, quality: VideoQuality, server: StreamServer) {
        self.geometry = geometry
        self.fps = fps
        self.quality = quality
        self.server = server
    }

    /// `completion` reports how starting went; `onFailure` reports a later breakdown.
    func start(onFailure: @escaping (Failure) -> Void, completion: @escaping (Failure?) -> Void) {
        guard let display = VirtualDisplay(
            name: "SideTab",
            pointsWide: geometry.pointsWide,
            pointsHigh: geometry.pointsHigh,
            hiDPI: geometry.hiDPI,
            refreshRate: Double(max(fps, 120)))  // a 120 Hz display lets capture hit 60 fps reliably
        else {
            completion(.displayRefused)
            return
        }
        self.display = display
        waitUntilOnline(display, attempt: 1) { [weak self] in
            guard let self else { return }
            // macOS sometimes mirrors a new display (it remembers the choice per
            // monitor). A mirrored display can't be captured, so always extend.
            if Session.makeExtended(display.displayID) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self, !self.stopped else { return }
                    self.startStreaming(display, onFailure: onFailure, completion: completion)
                }
            } else {
                self.startStreaming(display, onFailure: onFailure, completion: completion)
            }
        }
    }

    /// Turns off mirroring involving `id`. Returns true if anything changed.
    @discardableResult
    static func makeExtended(_ id: CGDirectDisplayID) -> Bool {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)

        let mirrored = ids.filter { other in
            other == id ? CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay
                        : CGDisplayMirrorsDisplay(other) == id
        }
        guard !mirrored.isEmpty else { return false }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        for display in mirrored {
            CGConfigureDisplayMirrorOfDisplay(config, display, kCGNullDirectDisplay)
        }
        let result = CGCompleteDisplayConfiguration(config, .permanently)
        Log.info(result == .success ? "Switched the display from mirroring to extended" : "Couldn't turn off mirroring (\(result.rawValue))")
        return result == .success
    }

    private func waitUntilOnline(_ display: VirtualDisplay, attempt: Int, then: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 1 ? 0.5 : 0.25)) { [weak self] in
            guard let self, !self.stopped else { return }
            if display.currentMode() == nil && attempt < 20 {
                self.waitUntilOnline(display, attempt: attempt + 1, then: then)
            } else {
                then()
            }
        }
    }

    private func startStreaming(_ display: VirtualDisplay,
                                onFailure: @escaping (Failure) -> Void,
                                completion: @escaping (Failure?) -> Void) {
        // Stream the display in whatever mode macOS actually brought it up in.
        let mode = display.currentMode()
        let width = (mode?.pixelsWide ?? geometry.pixelsWide) & ~1
        let height = (mode?.pixelsHigh ?? geometry.pixelsHigh) & ~1

        let encoder: H264Encoder
        do {
            encoder = try H264Encoder(
                width: width,
                height: height,
                fps: fps,
                bitrate: quality.bitrate(pixels: width * height, fps: fps)
            ) { [weak server, weak self] message, isKeyframe in
                server?.broadcast(message, isKeyframe: isKeyframe)
                self?.pipeline.async {
                    self?.framesSent += 1
                    self?.bytesSent += message.count
                }
            }
        } catch {
            completion(.encoder(error))
            return
        }
        Log.info("Streaming \(width)x\(height) pixels"
            + (encoder.usesLowLatencyRateControl ? " (low-latency encoder)" : ""))
        pipeline.sync {
            self.encoder = encoder
            self.keyframeWanted = true
        }
        startStats()
        startRepeats()

        let capturer = ScreenCapturer(
            queue: pipeline,
            onFrame: { [weak self] pixelBuffer in
                self?.handle(pixelBuffer)
            },
            onStop: { [weak self] error in
                DispatchQueue.main.async {
                    guard let self, !self.stopped else { return }
                    onFailure(.capture(error))
                }
            })
        self.capturer = capturer
        capturer.start(displayID: display.displayID, pixelsWide: width, pixelsHigh: height, fps: fps) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                completion(error.map { Failure.capture($0) })
            }
        }
    }

    /// Removes the display; windows on it move back to the Mac's screen.
    func stop(completion: @escaping () -> Void) {
        stopped = true
        statsTimer?.cancel()
        repeatTimer?.cancel()
        pipeline.sync {
            encoder = nil
            lastFrame = nil
        }
        let finish = { [self] in
            DispatchQueue.main.async {
                self.capturer = nil
                self.display = nil
                completion()
            }
        }
        if let capturer {
            capturer.stop(completion: finish)
        } else {
            finish()
        }
    }

    /// A viewer joined or fell behind and needs a full picture.
    func requestKeyframe() {
        pipeline.async {
            self.keyframeWanted = true
            if let frame = self.lastFrame {
                self.encode(frame)
                self.repeatsLeft = 6
            }
        }
    }

    private func startStats() {
        let timer = DispatchSource.makeTimerSource(queue: pipeline)
        timer.schedule(deadline: .now() + 5, repeating: .seconds(5))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.framesCaptured > 0 {
                Log.info(String(format: "Mac: captured %.0f fps, sent %.0f fps, %.1f Mbit/s",
                                Double(self.framesCaptured) / 5, Double(self.framesSent) / 5,
                                Double(self.bytesSent) * 8 / 5 / 1_000_000))
            }
            self.framesCaptured = 0
            self.framesSent = 0
            self.bytesSent = 0
        }
        timer.resume()
        statsTimer = timer
    }

    private func startRepeats() {
        let timer = DispatchSource.makeTimerSource(queue: pipeline)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self, self.repeatsLeft > 0, let frame = self.lastFrame else { return }
            let idleNanoseconds = DispatchTime.now().uptimeNanoseconds - self.lastEncode.uptimeNanoseconds
            guard idleNanoseconds > 14_000_000 else { return }
            self.repeatsLeft -= 1
            self.encode(frame)
        }
        timer.resume()
        repeatTimer = timer
    }

    private func handle(_ pixelBuffer: CVPixelBuffer) {
        framesCaptured += 1
        repeatsLeft = 6
        // Keep the latest picture so a viewer that joins while nothing is
        // moving on screen still gets an image straight away.
        lastFrame = pixelBuffer
        encode(pixelBuffer)
    }

    private func encode(_ pixelBuffer: CVPixelBuffer) {
        guard let encoder else { return }
        let forceKeyframe = keyframeWanted
        keyframeWanted = false
        lastEncode = DispatchTime.now()
        encoder.encode(pixelBuffer, forceKeyframe: forceKeyframe)
    }

}
