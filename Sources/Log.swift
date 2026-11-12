import Foundation

/// Prints to the terminal and mirrors every line into sidetab.log next to the app.
enum Log {
    private static let queue = DispatchQueue(label: "sidetab.log")
    private static var file: FileHandle?
    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static func start(file url: URL) {
        queue.sync {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            file = FileHandle(forWritingAtPath: url.path)
        }
    }

    static func info(_ message: String) {
        queue.sync {
            let line = Data("[\(clock.string(from: Date()))] \(message)\n".utf8)
            FileHandle.standardError.write(line)
            file?.write(line)
        }
    }
}
