import Foundation
import Network

/// Serves the viewer page (HTTP, `port`) and the frames (WebSocket, `port + 1`).
/// Each iPad asks for a frame with "next" and gets the newest one, so a slow network
/// lowers the frame rate instead of adding lag.
final class StreamServer {
    let token: String
    private let config: Config
    private let queue = DispatchQueue(label: "portrait.server")
    private var latest: Data?
    private var sequence: UInt64 = 0
    private var viewers: [ObjectIdentifier: Viewer] = [:]
    private var listeners: [NWListener] = []

    init(config: Config, token: String) {
        self.config = config
        self.token = token
    }

    func start() throws {
        // WebSocket listener for frames
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let wsParameters = NWParameters(tls: nil, tcp: tcp)
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        wsOptions.maximumMessageSize = 1 << 20
        wsParameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        wsParameters.allowLocalEndpointReuse = true
        let wsListener = try NWListener(using: wsParameters, on: Self.port(config.wsPort))
        wsListener.newConnectionHandler = { [weak self] connection in self?.acceptViewer(connection) }
        wsListener.stateUpdateHandler = Self.stateHandler(port: config.wsPort)
        wsListener.start(queue: queue)

        // Plain HTTP listener for the page
        let httpParameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        httpParameters.allowLocalEndpointReuse = true
        let httpListener = try NWListener(using: httpParameters, on: Self.port(config.httpPort))
        httpListener.newConnectionHandler = { [weak self] connection in self?.serveHTTP(connection) }
        httpListener.stateUpdateHandler = Self.stateHandler(port: config.httpPort)
        httpListener.start(queue: queue)

        listeners = [wsListener, httpListener]
    }

    func publish(_ jpeg: Data) {
        queue.async {
            self.sequence &+= 1
            self.latest = jpeg
            for viewer in self.viewers.values { viewer.pump() }
        }
    }

    // MARK: Viewers (all on `queue`)

    fileprivate func frame(after seen: UInt64) -> (data: Data, sequence: UInt64)? {
        guard sequence > seen, let latest = latest else { return nil }
        return (latest, sequence)
    }

    private func acceptViewer(_ connection: NWConnection) {
        let viewer = Viewer(connection: connection, server: self)
        viewers[ObjectIdentifier(viewer)] = viewer
        viewer.start(on: queue)
    }

    fileprivate func viewerAuthenticated(_ viewer: Viewer) {
        print("iPad connected (\(endpointName(viewer.connection))). Viewers: \(authenticatedCount)")
    }

    fileprivate func viewerClosed(_ viewer: Viewer) {
        let wasAuthenticated = viewer.authenticated
        viewers.removeValue(forKey: ObjectIdentifier(viewer))
        if wasAuthenticated { print("iPad disconnected. Viewers: \(authenticatedCount)") }
    }

    private var authenticatedCount: Int { viewers.values.filter { $0.authenticated }.count }

    private func endpointName(_ connection: NWConnection) -> String {
        if case let .hostPort(host, _) = connection.endpoint { return "\(host)" }
        return "\(connection.endpoint)"
    }

    // MARK: HTTP

    private func serveHTTP(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self = self,
                  let data = data,
                  let request = String(data: data, encoding: .utf8),
                  let requestLine = request.split(separator: "\r\n", maxSplits: 1).first else {
                connection.cancel()
                return
            }
            let parts = requestLine.split(separator: " ")
            let target = parts.count > 1 ? String(parts[1]) : "/"
            let components = URLComponents(string: target)
            let path = components?.path ?? "/"
            let providedToken = components?.queryItems?.first(where: { $0.name == "t" })?.value
            let authorised = providedToken == self.token

            let status: String, contentType: String, body: String
            switch (path, authorised) {
            case ("/", true):
                status = "200 OK"; contentType = "text/html; charset=utf-8"
                body = ViewerPage.html(token: self.token, wsPort: self.config.wsPort, name: self.config.name)
            case ("/manifest.webmanifest", true):
                status = "200 OK"; contentType = "application/manifest+json"
                body = ViewerPage.manifest(token: self.token, name: self.config.name)
            case ("/", false):
                status = "403 Forbidden"; contentType = "text/html; charset=utf-8"
                body = ViewerPage.wrongLink
            default:
                status = "404 Not Found"; contentType = "text/plain"; body = "Not found"
            }
            let bodyData = Data(body.utf8)
            let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(bodyData.count)\r\n"
                + "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(header.utf8) + bodyData,
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    // MARK: Helpers

    private static func port(_ value: UInt16) -> NWEndpoint.Port {
        NWEndpoint.Port(rawValue: value)!
    }

    private static func stateHandler(port: UInt16) -> (NWListener.State) -> Void {
        return { state in
            if case let .failed(error) = state {
                fail("Couldn't listen on port \(port) (\(error)). Is another copy running? Try --port 9090")
            }
        }
    }
}

/// One connected iPad.
private final class Viewer {
    let connection: NWConnection
    unowned let server: StreamServer
    var authenticated = false
    private var wantsFrame = false
    private var lastSent: UInt64 = 0
    private var closed = false

    init(connection: NWConnection, server: StreamServer) {
        self.connection = connection
        self.server = server
    }

    func start(on queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self = self, !self.closed else { return }
            if error != nil { self.close(); return }
            if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata, metadata.opcode == .close {
                self.close()
                return
            }
            if let data = data, let text = String(data: data, encoding: .utf8) {
                self.handle(text)
            }
            if !self.closed { self.receive() }
        }
    }

    private func handle(_ text: String) {
        if !authenticated {
            guard text == "hello " + server.token else { close(); return }
            authenticated = true
            server.viewerAuthenticated(self)
            return
        }
        if text == "next" {
            wantsFrame = true
            pump()
        }
    }

    func pump() {
        guard authenticated, wantsFrame, !closed,
              let frame = server.frame(after: lastSent) else { return }
        wantsFrame = false
        lastSent = frame.sequence
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        connection.send(content: frame.data, contentContext: context, isComplete: true,
                        completion: .contentProcessed { [weak self] error in
                            if error != nil { self?.close() }
                        })
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        server.viewerClosed(self)
    }
}
