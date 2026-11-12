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

    struct Battery: Equatable {
        var level: Int
        var isCharging: Bool
        var isFull: Bool
        var isPowered: Bool
    }

    /// Called on the link's own queue.
    var onStateChange: ((State) -> Void)?
    var onBatteryChange: ((Battery?) -> Void)?

    /// When on, SideTab makes the tablet take power from the Mac. Galaxy tablets
    /// otherwise often act as the power source and end up charging the Mac.
    private var chargeTablet = true
    private var battery: Battery?
    private var pollCount = 0
    private var lastChargeAttempt = Date.distantPast

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

    func setChargeTablet(_ on: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.chargeTablet = on
            self.lastChargeAttempt = .distantPast
            if self.state.isReady, let adb = self.adb {
                self.applyPowerRole(adb)
                // Re-read the battery once the switch has settled, so the menu updates.
                self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, self.state.isReady, let adb = self.adb else { return }
                    self.checkPower(adb)
                }
            }
        }
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
                pollCount += 1
                if pollCount % 5 == 0 {  // every 10 seconds
                    checkPower(adb)
                }
                return
            }
            guard reversePorts(adb) else {
                set(.noDevice)  // try again on the next poll
                return
            }
            set(.ready(name: deviceName(adb)))
            lastChargeAttempt = .distantPast
            checkPower(adb)
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
        if !newState.isReady && battery != nil {
            battery = nil
            onBatteryChange?(nil)
        }
        Log.info("Tablet: \(newState)")
        onStateChange?(newState)
    }

    // MARK: Power

    private func checkPower(_ adb: String) {
        let current = readBattery(adb)
        if current != battery {
            battery = current
            onBatteryChange?(current)
        }
        // Re-apply the chosen direction if the tablet has drifted back.
        guard let current, current.isPowered != chargeTablet,
              Date().timeIntervalSince(lastChargeAttempt) > 30
        else { return }
        applyPowerRole(adb)
    }

    private func readBattery(_ adb: String) -> Battery? {
        let output = AndroidLink.run(adb, ["shell", "dumpsys", "battery"]).output
        var values: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            if values[key] == nil {
                values[key] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        guard let level = values["level"].flatMap({ Int($0) }) else { return nil }
        let status = values["status"].flatMap { Int($0) } ?? 0
        let powered = ["AC powered", "USB powered", "Wireless powered", "Dock powered"].contains { values[$0] == "true" }
        // Android battery status: 2 = charging, 5 = full.
        return Battery(level: level, isCharging: status == 2, isFull: status == 5, isPowered: powered)
    }

    /// Sets which way power flows over the cable, keeping the tablet the data
    /// device so adb and the display keep working. USB-C has no "neither" mode:
    /// "sink" charges the tablet from the Mac, "source" has the tablet power the Mac.
    private func applyPowerRole(_ adb: String) {
        lastChargeAttempt = Date()
        let wanted = chargeTablet ? "sink" : "source"
        let usb = AndroidLink.run(adb, ["shell", "dumpsys", "usb"]).output
        guard let portID = AndroidLink.firstMatch(#"\bid=(\S+)"#, in: usb) else {
            Log.info("Charging: couldn't find the tablet's USB port")
            return
        }
        if AndroidLink.firstMatch(#"power_role=(\w+)"#, in: usb) == wanted { return }
        let result = AndroidLink.run(adb, ["shell", "dumpsys", "usb", "set-port-roles", portID, wanted, "device"])
        Log.info(result.status == 0
            ? "Charging: tablet port set to \(wanted) (\(chargeTablet ? "charging from the Mac" : "not charging"))"
            : "Charging: the tablet refused to switch power role: \(result.output)")
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
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
