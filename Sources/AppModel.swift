import AppKit
import CoreGraphics
import ScreenCaptureKit
import ServiceManagement

/// The app's state. The extra display exists only while SideTab is switched on
/// and a tablet is plugged in, the way a real monitor appears when you connect it.
/// Use on the main thread.
final class AppModel: ObservableObject {
    enum Problem: Equatable {
        case screenRecording
        case message(String)
    }

    static let port: UInt16 = 8080
    private static let defaults = UserDefaults.standard

    @Published var isEnabled: Bool {
        didSet {
            AppModel.defaults.set(isEnabled, forKey: "enabled")
            problem = nil
            update()
        }
    }

    @Published var resolution: ResolutionChoice {
        didSet {
            AppModel.defaults.set(resolution.rawValue, forKey: "resolution")
            problem = nil
            update()
        }
    }

    @Published var frameRate: FrameRate {
        didSet {
            AppModel.defaults.set(frameRate.rawValue, forKey: "frameRate")
            update()
        }
    }

    @Published var quality: VideoQuality {
        didSet {
            AppModel.defaults.set(quality.rawValue, forKey: "quality")
            update()
        }
    }

    @Published private(set) var tablet = AndroidLink.State.searching
    @Published private(set) var viewerCount = 0
    @Published private(set) var activeGeometry: DisplayGeometry?
    @Published private(set) var problem: Problem?
    @Published private(set) var launchAtLogin = false

    private let server = StreamServer()
    private let link = AndroidLink()
    private var session: Session?
    private var transitioning = false
    private var pendingStop: DispatchWorkItem?
    private var lastViewerOpen = Date.distantPast
    private var tabletPixels: CGSize
    /// The Mac's own screen. Only re-read while SideTab's display is absent,
    /// because adding it makes macOS report changes that mislead the lookup.
    private var macGeometry: DisplayGeometry?
    private var screenObserver: NSObjectProtocol?

    init() {
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        Log.start(file: logs.appendingPathComponent("SideTab.log"))

        isEnabled = AppModel.defaults.object(forKey: "enabled") as? Bool ?? true
        resolution = ResolutionChoice(rawValue: AppModel.defaults.string(forKey: "resolution") ?? "") ?? .sameAsMac
        frameRate = FrameRate(rawValue: AppModel.defaults.integer(forKey: "frameRate")) ?? .sixty
        quality = VideoQuality(rawValue: AppModel.defaults.string(forKey: "quality") ?? "") ?? .high
        let width = AppModel.defaults.double(forKey: "tabletWidth")
        let height = AppModel.defaults.double(forKey: "tabletHeight")
        tabletPixels = width > 0 && height > 0 ? CGSize(width: width, height: height) : CGSize(width: 2560, height: 1600)
        launchAtLogin = SMAppService.mainApp.status == .enabled
        macGeometry = ResolutionChoice.macGeometry(excluding: nil)

        connect()
    }

    // MARK: What the menu shows

    var isConnected: Bool { activeGeometry != nil && viewerCount > 0 }

    var deviceName: String {
        if case .ready(let name) = tablet { return name }
        return "Tablet"
    }

    var statusLine: String {
        if !isEnabled { return "Off" }
        switch problem {
        case .screenRecording: return "Needs permission to record the screen"
        case .message(let message): return message
        case nil: break
        }
        switch tablet {
        case .searching: return "Looking for your tablet…"
        case .missingADB: return "Android platform tools aren't installed"
        case .noDevice: return viewerCount > 0 ? "Connected" : "Connect your tablet with a USB-C cable"
        case .unauthorized: return "Unlock your tablet and allow USB debugging"
        case .several: return "Disconnect other Android devices"
        case .ready:
            if viewerCount > 0 { return "Connected via USB" }
            return activeGeometry == nil ? "Preparing display…" : "Opening on your tablet…"
        }
    }

    func label(for choice: ResolutionChoice) -> String {
        choice.geometry(tabletPixels: tabletPixels, mac: macGeometry).label
    }

    // MARK: Actions

    func openDisplaySettings() {
        open("x-apple.systempreferences:com.apple.Displays-Settings.extension")
    }

    func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    func openViewerOnTablet() {
        lastViewerOpen = Date()
        link.openViewer()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.info("Launch at login: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Screen recording permission only takes effect after a relaunch.
    func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.7; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }

    func quit() {
        NSApp.terminate(nil)
    }

    private func open(_ address: String) {
        if let url = URL(string: address) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Wiring

    private func connect() {
        server.onViewerCountChanged = { [weak self] count in
            DispatchQueue.main.async {
                self?.viewerCount = count
                self?.update()
            }
        }
        server.onKeyframeNeeded = { [weak self] in
            DispatchQueue.main.async {
                self?.session?.requestKeyframe()
            }
        }
        server.onTextMessage = { [weak self] text in
            DispatchQueue.main.async {
                self?.handleViewerMessage(text)
            }
        }
        server.onFailure = { [weak self] message in
            DispatchQueue.main.async {
                self?.problem = .message(message)
                self?.update()
            }
        }
        let web = Bundle.main.resourceURL?.appendingPathComponent("web") ?? URL(fileURLWithPath: "web")
        do {
            try server.start(port: AppModel.port, webDirectory: web)
        } catch {
            problem = .message(error.localizedDescription)
        }

        link.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.tabletChanged(state)
            }
        }
        link.start(port: AppModel.port)

        // "Same as Mac" follows the Mac's screen when its resolution changes.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshMacGeometry()
            self?.update()
        }

        DispatchQueue.main.async {
            self.update()
        }
    }

    // MARK: Running the display

    private var wantsDisplay: Bool {
        isEnabled && problem == nil && (tablet.isReady || viewerCount > 0)
    }

    /// Brings the display in line with the current state. Safe to call any time.
    private func update() {
        server.setStatus(isEnabled ? "on" : "off")
        guard !transitioning else { return }

        if wantsDisplay {
            pendingStop?.cancel()
            pendingStop = nil
            let desired = resolution.geometry(tabletPixels: tabletPixels, mac: macGeometry)
            if let session {
                if session.geometry != desired || session.fps != frameRate.rawValue || session.quality != quality {
                    stopSession()  // starts again at the new size once it is gone
                }
            } else {
                startSession(desired)
            }
        } else if session != nil && pendingStop == nil {
            // Wait a moment before removing the display, so a reloading page or a
            // wobbly cable doesn't throw every window back onto the Mac.
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingStop = nil
                if !self.wantsDisplay && !self.transitioning {
                    self.stopSession()
                }
            }
            pendingStop = work
            let delay: Double = isEnabled && problem == nil ? 2.5 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func refreshMacGeometry() {
        guard session == nil, !transitioning,
              let current = ResolutionChoice.macGeometry(excluding: nil),
              current != macGeometry
        else { return }
        Log.info("Mac screen is \(current.label) points at \(current.scale)x")
        macGeometry = current
    }

    private func startSession(_ geometry: DisplayGeometry) {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        Log.info("Adding display: \(geometry.label) points at \(geometry.scale)x, "
            + "\(frameRate.rawValue) fps, \(quality.title) quality")
        let session = Session(geometry: geometry, fps: frameRate.rawValue, quality: quality, server: server)
        self.session = session
        transitioning = true
        session.start(
            onFailure: { [weak self, weak session] failure in
                guard let self, let session, self.session === session else { return }
                self.fail(failure)
            },
            completion: { [weak self, weak session] failure in
                guard let self, let session, self.session === session else { return }
                self.transitioning = false
                if let failure {
                    self.fail(failure)
                    return
                }
                self.activeGeometry = geometry
                self.openViewerSoon()
                self.update()
            })
    }

    private func stopSession() {
        guard let session else { return }
        Log.info("Removing display")
        self.session = nil
        activeGeometry = nil
        transitioning = true
        session.stop { [weak self] in
            self?.transitioning = false
            self?.refreshMacGeometry()
            self?.update()
        }
    }

    private func fail(_ failure: Session.Failure) {
        Log.info("Display problem: \(failure.localizedDescription)")
        if case .capture(let error) = failure, (error as NSError).code == SCStreamError.Code.userStopped.rawValue {
            // Stopped from macOS's screen-recording indicator: start over cleanly.
            transitioning = false
            stopSession()
            return
        }
        if case .capture = failure, !CGPreflightScreenCaptureAccess() {
            problem = .screenRecording
        } else {
            problem = .message(failure.localizedDescription)
        }
        transitioning = false
        stopSession()
    }

    // MARK: Tablet

    private func tabletChanged(_ state: AndroidLink.State) {
        let wasReady = tablet.isReady
        tablet = state
        if state.isReady && !wasReady {
            openViewerSoon()
        }
        update()
    }

    /// A viewer page that is already open on the tablet reconnects by itself;
    /// open a new one only if nothing shows up.
    private func openViewerSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.isEnabled, self.tablet.isReady, self.activeGeometry != nil,
                  self.viewerCount == 0, Date().timeIntervalSince(self.lastViewerOpen) > 10
            else { return }
            self.openViewerOnTablet()
        }
    }

    /// The viewer reports the tablet's screen size so the other resolutions fit it exactly.
    private func handleViewerMessage(_ text: String) {
        if text.hasPrefix("{\"type\":\"stats\"") {
            Log.info("Tablet: \(text)")
            return
        }
        guard let data = text.data(using: .utf8),
              let hello = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              hello["type"] as? String == "hello",
              let width = (hello["w"] as? NSNumber)?.intValue,
              let height = (hello["h"] as? NSNumber)?.intValue,
              width > 0, height > 0
        else { return }

        func roundToEight(_ value: Int) -> Double { Double((value + 4) / 8 * 8) }
        let size = CGSize(width: roundToEight(max(width, height)), height: roundToEight(min(width, height)))
        guard abs(size.width - tabletPixels.width) > 8 || abs(size.height - tabletPixels.height) > 8 else { return }

        Log.info("Tablet screen is \(Int(size.width))x\(Int(size.height)) pixels")
        tabletPixels = size
        AppModel.defaults.set(size.width, forKey: "tabletWidth")
        AppModel.defaults.set(size.height, forKey: "tabletHeight")
        update()
    }
}
