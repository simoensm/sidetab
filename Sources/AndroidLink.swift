import Foundation

/// Watches the USB cable for an Android tablet. When one is there it points the
/// tablet's localhost ports back at this Mac (adb reverse), so the viewer page
/// reaches SideTab through the cable. Needs USB debugging on the tablet.
final class AndroidLink {
    enum State: Equatable {
        case searching
        case missingADB
        case noDevice
        case unauthorized
        case several
        case ready(name: String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    /// Called on the link's own queue.
    var onStateChange: ((State) -> Void)?

    private let queue = DispatchQueue(label: "sidetab.adb")
    private var timer: DispatchSourceTimer?
    private var adb: String?
    private var port: UInt16 = 8080
    private var state = State.searching

    func start(port: UInt16) {
        self.port = port
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(2))
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        timer.resume()
        self.timer = timer
    }

    /// Opens the viewer page in the tablet's browser.
    func openViewer() {
        queue.async { [weak self] in
            guard let self, let adb = self.adb else { return }
            let result = AndroidLink.run(adb, [
                "shell", "am", "start",
                "-a", "android.intent.action.VIEW",
                "-d", "http://localhost:\(self.port)"
            ])
            Log.info(result.status == 0 ? "Opened the viewer on the tablet" : "Couldn't open the tablet's browser")
        }
    }

    private func poll() {
        guard let adb = adb ?? AndroidLink.findADB() else {
            set(.missingADB)
            return
        }
        self.adb = adb

        let result = AndroidLink.run(adb, ["get-state"])
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)

        if result.status == 0 && text.hasSuffix("device") {
            if state.isReady {
                // A quick unplug and replug can slip between two polls and drop
                // the port mapping, so make sure it is still there.
                let mappings = AndroidLink.run(adb, ["reverse", "--list"])
                if mappings.status == 0 && !mappings.output.contains("tcp:\(port + 1) tcp:\(port + 1)") {
                    _ = reversePorts(adb)
                }
                return
            }
            guard reversePorts(adb) else {
                set(.noDevice)  // try again on the next poll
                return
            }
            set(.ready(name: deviceName(adb)))
        } else if text.contains("unauthorized") {
            set(.unauthorized)
        } else if text.contains("more than one") {
            set(.several)
        } else {
            set(.noDevice)
        }
    }

    private func set(_ newState: State) {
        guard newState != state else { return }
        state = newState
        Log.info("Tablet: \(newState)")
        onStateChange?(newState)
    }

    private func reversePorts(_ adb: String) -> Bool {
        let page = AndroidLink.run(adb, ["reverse", "tcp:\(port)", "tcp:\(port)"])
        let video = AndroidLink.run(adb, ["reverse", "tcp:\(port + 1)", "tcp:\(port + 1)"])
        if page.status != 0 || video.status != 0 {
            Log.info("adb reverse failed: \(page.output) \(video.output)")
            return false
        }
        return true
    }

    /// "Galaxy Tab S9" rather than "SM-X710" when the tablet has a friendly name.
    private func deviceName(_ adb: String) -> String {
        let candidates = [
            ["shell", "settings", "get", "global", "device_name"],
            ["shell", "getprop", "ro.product.model"]
        ]
        for arguments in candidates {
            let name = AndroidLink.run(adb, arguments).output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty && name != "null" && !name.contains("\n") {
                return name
            }
        }
        return "Tablet"
    }

    private static func findADB() -> String? {
        // Apps launched from Finder don't get the terminal's PATH, so look in the usual places.
        var candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { "\($0)/adb" }
        candidates += [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
