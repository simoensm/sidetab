import Foundation
import Network

enum ServerError: LocalizedError {
    case badPort

    var errorDescription: String? { "That port number can't be used." }
}

/// Serves the viewer page over HTTP on `port` and pushes video to viewers over
/// a WebSocket on `port + 1`. Both listen on this Mac's loopback interface only;
/// the tablet reaches them through the USB cable (adb reverse), never over Wi-Fi.
///
/// Text messages to the viewer: "on" / "off" (whether SideTab is switched on).
/// Binary messages: one encoded frame each (see H264Encoder).
final class StreamServer {
    /// All callbacks arrive on the server's own queue.
    var onViewerCountChanged: ((Int) -> Void)?
    var onKeyframeNeeded: (() -> Void)?
    var onTextMessage: ((String) -> Void)?
    var onFailure: ((String) -> Void)?

    private final class Viewer {
        let connection: NWConnection
        var waitingForKeyframe = true
        var pendingSends = 0

        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    /// A viewer with this many frames still queued is falling behind.
    private static let backlogLimit = 30

    private let queue = DispatchQueue(label: "sidetab.server", qos: .userInteractive)
    private var listeners: [NWListener] = []
    private var viewers: [ObjectIdentifier: Viewer] = [:]
    private var webDirectory = URL(fileURLWithPath: ".")
    private var status = "off"

    func start(port: UInt16, webDirectory: URL) throws {
        self.webDirectory = webDirectory
        guard let httpPort = NWEndpoint.Port(rawValue: port),
              let webSocketPort = NWEndpoint.Port(rawValue: port + 1)
        else { throw ServerError.badPort }

        let httpParameters = NWParameters.tcp
        httpParameters.requiredInterfaceType = .loopback
        httpParameters.allowLocalEndpointReuse = true
        let http = try NWListener(using: httpParameters, on: httpPort)
        http.newConnectionHandler = { [weak self] connection in
            self?.serveHTTP(connection)
        }
        watch(http, port: port)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let webSocketParameters = NWParameters(tls: nil, tcp: tcp)
        webSocketParameters.requiredInterfaceType = .loopback
        webSocketParameters.allowLocalEndpointReuse = true
        let webSocketOptions = NWProtocolWebSocket.Options()
        webSocketOptions.autoReplyPing = true
        webSocketParameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)
        let webSocket = try NWListener(using: webSocketParameters, on: webSocketPort)
        webSocket.newConnectionHandler = { [weak self] connection in
            self?.acceptViewer(connection)
        }
        watch(webSocket, port: port + 1)

        listeners = [http, webSocket]
        http.start(queue: queue)
        webSocket.start(queue: queue)
    }

    private func watch(_ listener: NWListener, port: UInt16) {
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                Log.info("Can't listen on port \(port): \(error)")
                self?.onFailure?("Port \(port) is in use. Quit any other copy of SideTab.")
            }
        }
    }

    /// Tells every viewer whether SideTab is switched on.
    func setStatus(_ newStatus: String) {
        queue.async { [weak self] in
            guard let self, self.status != newStatus else { return }
            self.status = newStatus
            for viewer in self.viewers.values {
                self.send(text: newStatus, to: viewer)
            }
        }
    }

    // MARK: Viewer page

    private func serveHTTP(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            // Request line looks like: GET /path?query HTTP/1.1
            let words = request.split(separator: " ", maxSplits: 2)
            let target = words.count > 1 ? String(words[1]) : "/"
            let path = target.split(separator: "?", maxSplits: 1).first.map { String($0) } ?? "/"

            var status = "200 OK"
            var contentType = "text/html; charset=utf-8"
            var body = Data()
            if path == "/" || path == "/index.html" {
                if let page = try? Data(contentsOf: self.webDirectory.appendingPathComponent("index.html")) {
                    body = page
                } else {
                    status = "500 Internal Server Error"
                    contentType = "text/plain; charset=utf-8"
                    body = Data("SideTab can't find its viewer page.".utf8)
                }
            } else {
                status = "404 Not Found"
                contentType = "text/plain; charset=utf-8"
                body = Data("Not found".utf8)
            }

            let head = "HTTP/1.1 \(status)\r\n"
                + "Content-Type: \(contentType)\r\n"
                + "Content-Length: \(body.count)\r\n"
                + "Cache-Control: no-store\r\n"
                + "Connection: close\r\n\r\n"
            var response = Data(head.utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    // MARK: Video

    private func acceptViewer(_ connection: NWConnection) {
        let viewer = Viewer(connection: connection)
        let id = ObjectIdentifier(viewer)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.viewers[id] = viewer
                Log.info("Viewer connected (\(self.viewers.count) watching)")
                self.send(text: self.status, to: viewer)
                self.onViewerCountChanged?(self.viewers.count)
                self.onKeyframeNeeded?()
                self.receive(from: viewer)
            case .failed:
                connection.cancel()
            case .cancelled:
                connection.stateUpdateHandler = nil
                if self.viewers.removeValue(forKey: id) != nil {
                    Log.info("Viewer disconnected (\(self.viewers.count) watching)")
                    self.onViewerCountChanged?(self.viewers.count)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(from viewer: Viewer) {
        viewer.connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil,
                  let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata
            else {
                // An error, or the end of the stream: the viewer is gone.
                viewer.connection.cancel()
                return
            }
            switch metadata.opcode {
            case .close:
                viewer.connection.cancel()
                return
            case .text:
                if let data, let text = String(data: data, encoding: .utf8) {
                    self.onTextMessage?(text)
                }
            default:
                break
            }
            self.receive(from: viewer)
        }
    }

    private func send(text: String, to viewer: Viewer) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "status", metadata: [metadata])
        viewer.connection.send(content: Data(text.utf8), contentContext: context, isComplete: true,
                               completion: .contentProcessed { _ in })
    }

    /// Sends one encoded frame to every viewer that can use it.
    func broadcast(_ message: Data, isKeyframe: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            for viewer in self.viewers.values {
                if viewer.waitingForKeyframe {
                    // Join (or rejoin) on a keyframe, and only once the backlog is gone.
                    guard isKeyframe, viewer.pendingSends <= 2 else { continue }
                    viewer.waitingForKeyframe = false
                } else if viewer.pendingSends > StreamServer.backlogLimit {
                    // Too slow to keep up: drop frames instead of letting delay pile up.
                    viewer.waitingForKeyframe = true
                    continue
                }

                viewer.pendingSends += 1
                let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
                let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
                viewer.connection.send(
                    content: message,
                    contentContext: context,
                    isComplete: true,
                    completion: .contentProcessed { [weak self] error in
                        viewer.pendingSends -= 1
                        if error != nil {
                            viewer.connection.cancel()
                        } else if viewer.pendingSends == 0 && viewer.waitingForKeyframe {
                            self?.onKeyframeNeeded?()
                        }
                    })
            }
        }
    }
}
