import Foundation
import Network

/// Three listeners:
///   `port`      plain HTTP – setup page and the CA certificate for the iPad to install
///   `port + 1`  HTTPS – the viewer page (WebCodecs only works on secure pages)
///   `port + 2`  secure WebSocket – codec config (text) and H.264 frames (binary)
/// Each iPad acknowledges every frame. If too many are unacknowledged it skips frames and resumes
/// at the next keyframe, so a slow network lowers the frame rate instead of adding lag.
final class StreamServer {
    let token: String
    var onKeyframeNeeded: (() -> Void)?
    var onInput: ((String) -> Void)?   // touch / Pencil messages from an authenticated iPad
    private let config: Config
    private let queue = DispatchQueue(label: "portrait.server")
    private var codec: (message: String, version: Int)?
    private var viewers: [ObjectIdentifier: Viewer] = [:]
    private var listeners: [NWListener] = []

    init(config: Config, token: String) {
        self.config = config
        self.token = token
    }

    func start(tls: NWProtocolTLS.Options) throws {
        // Secure WebSocket listener for frames
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let wsParameters = NWParameters(tls: tls, tcp: tcp)
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        wsOptions.maximumMessageSize = 64 * 1024
        wsParameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        wsParameters.allowLocalEndpointReuse = true
        let wsListener = try NWListener(using: wsParameters, on: Self.port(config.wsPort))
        wsListener.newConnectionHandler = { [weak self] connection in self?.acceptViewer(connection) }
        wsListener.stateUpdateHandler = Self.stateHandler(port: config.wsPort)

        let pageParameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        pageParameters.allowLocalEndpointReuse = true
        let pageListener = try NWListener(using: pageParameters, on: Self.port(config.pagePort))
        pageListener.newConnectionHandler = { [weak self] connection in self?.serveHTTP(connection, secure: true) }
        pageListener.stateUpdateHandler = Self.stateHandler(port: config.pagePort)

        let setupParameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        setupParameters.allowLocalEndpointReuse = true
        let setupListener = try NWListener(using: setupParameters, on: Self.port(config.httpPort))
        setupListener.newConnectionHandler = { [weak self] connection in self?.serveHTTP(connection, secure: false) }
        setupListener.stateUpdateHandler = Self.stateHandler(port: config.httpPort)

        listeners = [wsListener, pageListener, setupListener]
        for listener in listeners { listener.start(queue: queue) }
    }

    func publish(_ newConfig: CodecConfig) {
        let message = """
        {"codec":"\(newConfig.codec)","width":\(newConfig.width),"height":\(newConfig.height),\
        "description":"\(newConfig.avcC.base64EncodedString())"}
        """
        queue.async {
            self.codec = (message, (self.codec?.version ?? 0) + 1)
        }
    }

    func publish(_ frame: EncodedFrame) {
        var message = Data([frame.isKey ? 1 : 0])   // 1-byte header: keyframe flag
        message.append(frame.data)
        queue.async {
            for viewer in self.viewers.values { viewer.offer(message, isKey: frame.isKey) }
        }
    }

    // MARK: Viewers (all on `queue`)

    fileprivate var currentCodec: (message: String, version: Int)? { codec }

    fileprivate func requestKeyframe() { onKeyframeNeeded?() }

    fileprivate func input(_ message: String) { onInput?(message) }

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

    /// A device that doesn't trust the certificate drops the TLS handshake; say so instead of staying silent.
    fileprivate func tlsFailureLogger(_ connection: NWConnection) -> (NWConnection.State) -> Void {
        return { [weak self] state in
            guard let self = self, case let .failed(error) = state, case .tls = error else { return }
            print("Secure connection from \(self.endpointName(connection)) failed: \(error). "
                  + "Is \"\(Certificates.caName)\" turned on in Certificate Trust Settings?")
        }
    }

    fileprivate func endpointName(_ connection: NWConnection) -> String {
        if case let .hostPort(host, _) = connection.endpoint { return "\(host)" }
        return "\(connection.endpoint)"
    }

    // MARK: HTTP

    private func serveHTTP(_ connection: NWConnection, secure: Bool) {
        if secure { connection.stateUpdateHandler = tlsFailureLogger(connection) }
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

            var status = "200 OK", contentType = "text/html; charset=utf-8", extraHeaders = ""
            var body = Data()
            switch (secure, path, authorised) {
            case (true, "/", true):
                print("Viewer page opened (\(self.endpointName(connection))).")
                body = Data(ViewerPage.html(token: self.token, wsPort: self.config.wsPort, name: self.config.name).utf8)
            case (true, "/manifest.webmanifest", true):
                contentType = "application/manifest+json"
                body = Data(ViewerPage.manifest(token: self.token, name: self.config.name).utf8)
            case (true, "/ping", _):
                // The setup page fetches this to find out whether the iPad trusts the certificate yet.
                status = "204 No Content"; contentType = "text/plain"
                extraHeaders = "Access-Control-Allow-Origin: *\r\n"
            case (false, "/", true):
                print("Setup page opened (\(self.endpointName(connection))).")
                body = Data(SetupPage.html(token: self.token, pagePort: self.config.pagePort).utf8)
            case (false, "/PortraitDisplay-CA.cer", _):
                print("Certificate downloaded (\(self.endpointName(connection))).")
                contentType = "application/x-x509-ca-cert"
                body = Certificates.caDER()
            case (_, "/", false):
                status = "403 Forbidden"
                body = Data(ViewerPage.wrongLink.utf8)
            default:
                status = "404 Not Found"; contentType = "text/plain"; body = Data("Not found".utf8)
            }
            let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
                + "Cache-Control: no-store\r\n\(extraHeaders)Connection: close\r\n\r\n"
            connection.send(content: Data(header.utf8) + body,
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
    /// Frames sent but not yet acknowledged. A few in flight keeps the pipe full on Wi-Fi;
    /// beyond that, frames would just queue up as lag.
    private static let maxInFlight = 4

    let connection: NWConnection
    unowned let server: StreamServer
    var authenticated = false
    private var inFlight = 0
    private var waitingForKey = true     // H.264 deltas are useless until the next keyframe
    private var keyRequested = false
    private var codecVersionSent = 0
    private var closed = false

    init(connection: NWConnection, server: StreamServer) {
        self.connection = connection
        self.server = server
    }

    func start(on queue: DispatchQueue) {
        let logTLSFailure = server.tlsFailureLogger(connection)
        connection.stateUpdateHandler = { [weak self] state in
            logTLSFailure(state)
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
            resync()
            return
        }
        switch text {
        case "ack":
            inFlight = max(0, inFlight - 1)
            if waitingForKey && !keyRequested && inFlight < Self.maxInFlight { requestKey() }
        case "key":   // the iPad's decoder failed or was reset
            resync()
        default:
            if text.hasPrefix("c ") || text.hasPrefix("p ") || text.hasPrefix("s ") { server.input(text) }
        }
    }

    private func resync() {
        inFlight = 0
        waitingForKey = true
        codecVersionSent = 0   // the decoder needs its config again too
        requestKey()
    }

    private func requestKey() {
        keyRequested = true
        server.requestKeyframe()
    }

    func offer(_ frame: Data, isKey: Bool) {
        guard authenticated, !closed else { return }
        let roomToSend = inFlight < Self.maxInFlight
        if waitingForKey {
            guard isKey, roomToSend else {
                if isKey { keyRequested = false }   // that keyframe is gone; ask again once there's room
                if roomToSend && !keyRequested { requestKey() }
                return
            }
        } else if !roomToSend {
            // Behind: drop this frame and everything up to a keyframe, requested once acks free up room.
            waitingForKey = true
            keyRequested = false
            return
        }
        if isKey {
            waitingForKey = false
            keyRequested = false
            if let codec = server.currentCodec, codec.version != codecVersionSent {
                codecVersionSent = codec.version
                send(Data(codec.message.utf8), opcode: .text)
            }
        }
        inFlight += 1
        send(frame, opcode: .binary)
    }

    private func send(_ data: Data, opcode: NWProtocolWebSocket.Opcode) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true,
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
