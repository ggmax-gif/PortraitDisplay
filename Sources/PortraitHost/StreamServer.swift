import Foundation
import Network

/// Three listeners:
///   `port`      plain HTTP – setup page and the CA certificate for the iPad to install
///   `port + 1`  HTTPS – the viewer page (WebCodecs only works on secure pages)
///   `port + 2`  secure WebSocket – codec config (text) and H.264 / HEVC frames (binary)
/// Each iPad acknowledges every frame, with at most 4 unacknowledged. The capturer reads `freeSlots`
/// and doesn't encode frames the iPads can't take yet, so a slow network lowers the frame rate
/// instead of adding lag. Dropping an already-encoded frame (rare) resumes at the next keyframe.
final class StreamServer {
    let token: String
    var onKeyframeNeeded: (() -> Void)?
    var onInput: ((String) -> Void)?   // touch / Pencil messages from an authenticated iPad
    var macStats: (() -> String)?      // capture / encode part of the stats line
    var onRoom: (() -> Void)?          // an iPad can take more frames again
    var onViewerGone: (() -> Void)?    // an authenticated iPad disconnected
    var onViewerCount: ((Int) -> Void)?   // authenticated iPads, after each connect / disconnect
    var onCodecWanted: ((VideoCodec) -> Void)?
    private var wantedCodec: VideoCodec
    private let slotsLock = NSLock()
    private var slots = 0              // guarded by slotsLock
    static let statsInterval = 2.0
    private var statsTimer: DispatchSourceTimer?
    private let config: Config
    private let queue = DispatchQueue(label: "portrait.server")
    private var codec: (message: String, version: Int)?
    private var viewers: [ObjectIdentifier: Viewer] = [:]
    private var listeners: [NWListener] = []

    init(config: Config, token: String) {
        self.config = config
        self.token = token
        wantedCodec = config.codec
    }

    /// The codec the encoder should start with.
    var initialCodec: VideoCodec { wantedCodec }

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

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.statsInterval, repeating: Self.statsInterval)
        timer.setEventHandler { [weak self] in self?.reportStats() }
        timer.resume()
        statsTimer = timer
    }

    /// Every 2 s while frames flow: one line per iPad, printed and shown on its overlay.
    private func reportStats() {
        let mac = macStats?() ?? ""   // always called, so its counters reset each interval
        for viewer in viewers.values {
            guard let line = viewer.takeStats(seconds: Self.statsInterval) else { continue }
            let text = "\(mac) · \(line)"
            print("Stats (\(endpointName(viewer.connection))): \(text)")
            Status.emit("stats", text)
            if let json = try? JSONSerialization.data(withJSONObject: ["stats": text]) {
                viewer.sendText(json)
            }
        }
    }

    func publish(_ newConfig: CodecConfig) {
        let message = """
        {"codec":"\(newConfig.codec)","width":\(newConfig.width),"height":\(newConfig.height),\
        "description":"\(newConfig.description.base64EncodedString())"}
        """
        queue.sync {
            self.codec = (message, (self.codec?.version ?? 0) + 1)
        }
    }

    /// Synchronous on purpose: the capturer's next "is there room?" check must already see this
    /// frame counted, or it encodes one frame too many and that frame gets skipped (→ keyframe).
    func publish(_ frame: EncodedFrame) {
        var message = Data([frame.isKey ? 1 : 0])   // 1-byte header: keyframe flag
        message.append(frame.data)
        queue.sync {
            for viewer in self.viewers.values { viewer.offer(message, isKey: frame.isKey) }
        }
    }

    // MARK: Viewers (all on `queue`)

    fileprivate var currentCodec: (message: String, version: Int)? { codec }

    fileprivate func requestKeyframe() { onKeyframeNeeded?() }

    /// How many more frames every connected iPad can take right now (0 with none connected).
    /// The capturer checks this before encoding: skipping a frame before it's encoded is free,
    /// skipping it after costs a keyframe, and keyframes are what made video stutter.
    var freeSlots: Int {
        slotsLock.lock(); defer { slotsLock.unlock() }
        return slots
    }

    fileprivate func updateSlots() {
        let free = viewers.values.filter { $0.authenticated }.map { $0.freeSlots }.min() ?? 0
        slotsLock.lock()
        let grew = free > slots
        slots = free
        slotsLock.unlock()
        if grew { onRoom?() }
    }

    fileprivate func input(_ message: String) { onInput?(message) }

    private func acceptViewer(_ connection: NWConnection) {
        let viewer = Viewer(connection: connection, server: self)
        viewers[ObjectIdentifier(viewer)] = viewer
        viewer.start(on: queue)
    }

    fileprivate func viewerAuthenticated(_ viewer: Viewer) {
        print("iPad connected (\(endpointName(viewer.connection)), "
              + "\(viewer.decodesHEVC ? "decodes HEVC" : "H.264 only")). Viewers: \(authenticatedCount)")
        Status.emit("viewers", String(authenticatedCount))
        onViewerCount?(authenticatedCount)
        chooseCodec()
    }

    /// With --codec hevc: one encoder serves every iPad, so HEVC only while all of them can decode it.
    /// With nobody connected, the current choice stays.
    private func chooseCodec() {
        let connected = viewers.values.filter { $0.authenticated }
        guard !connected.isEmpty else { return }
        let codec: VideoCodec = config.codec == .hevc && connected.allSatisfy { $0.decodesHEVC } ? .hevc : .h264
        guard codec != wantedCodec else { return }
        wantedCodec = codec
        onCodecWanted?(codec)
    }

    fileprivate func viewerClosed(_ viewer: Viewer) {
        let wasAuthenticated = viewer.authenticated
        viewers.removeValue(forKey: ObjectIdentifier(viewer))
        updateSlots()
        if wasAuthenticated {
            print("iPad disconnected. Viewers: \(authenticatedCount)")
            Status.emit("viewers", String(authenticatedCount))
            onViewerCount?(authenticatedCount)
            chooseCodec()
            onViewerGone?()
        }
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
                let other = Status.enabled ? "pick another Port in Settings" : "try --port 9090"
                fail("Couldn't listen on port \(port) (\(error)). Is another copy running? Otherwise \(other).")
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
    private(set) var decodesHEVC = false
    private var inFlight = 0
    private var waitingForKey = true     // deltas are useless until the next keyframe
    private var keyRequested = false
    private var codecVersionSent = 0
    private var closed = false
    // Stats since the last report.
    private var sentTimes: [TimeInterval] = []   // send time of each unacknowledged frame, oldest first
    private var sent = 0, skipped = 0, keys = 0, bytes = 0
    private var roundTrips: [Double] = []
    private var decodeMs: String?

    var freeSlots: Int { max(0, Self.maxInFlight - inFlight) }

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
            // "hello <token>", plus " hevc" if the iPad's decoder supports HEVC.
            let words = text.split(separator: " ")
            guard words.count >= 2, words[0] == "hello", words[1] == server.token else { close(); return }
            decodesHEVC = words.dropFirst(2).contains("hevc")
            authenticated = true
            server.viewerAuthenticated(self)
            resync()
            return
        }
        switch text {
        case "ack":
            inFlight = max(0, inFlight - 1)
            if !sentTimes.isEmpty {
                roundTrips.append(ProcessInfo.processInfo.systemUptime - sentTimes.removeFirst())
            }
            if waitingForKey && !keyRequested && inFlight < Self.maxInFlight { requestKey() }
            server.updateSlots()
        case "key":   // the iPad's decoder failed or was reset
            resync()
        default:
            if text.hasPrefix("d ") { decodeMs = String(text.dropFirst(2)); return }
            if text.hasPrefix("c ") || text.hasPrefix("p ") || text.hasPrefix("s ") { server.input(text) }
        }
    }

    private func resync() {
        inFlight = 0
        sentTimes.removeAll()
        waitingForKey = true
        codecVersionSent = 0   // the decoder needs its config again too
        requestKey()           // before updateSlots, so the frame that room allows is the keyframe
        server.updateSlots()
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
                skipped += 1
                if isKey { keyRequested = false }   // that keyframe is gone; ask again once there's room
                if roomToSend && !keyRequested { requestKey() }
                return
            }
        } else if !roomToSend {
            // Behind: drop this frame and everything up to a keyframe, requested once acks free up room.
            waitingForKey = true
            keyRequested = false
            skipped += 1
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
        sent += 1
        bytes += frame.count
        if isKey { keys += 1 }
        sentTimes.append(ProcessInfo.processInfo.systemUptime)
        send(frame, opcode: .binary)
        server.updateSlots()
    }

    func sendText(_ data: Data) {
        guard authenticated, !closed else { return }
        send(data, opcode: .text)
    }

    /// Nil when nothing was sent or skipped (still screen), so the log stays quiet.
    func takeStats(seconds: Double) -> String? {
        defer { sent = 0; skipped = 0; keys = 0; bytes = 0; roundTrips = []; decodeMs = nil }
        guard authenticated, sent + skipped > 0 else { return nil }
        let rate = { (n: Int) in Int((Double(n) / seconds).rounded()) }
        var line = "sent \(rate(sent))/s (skipped \(rate(skipped))/s, \(keys) keyframes), "
            + String(format: "%.1f Mbit/s", Double(bytes) * 8 / seconds / 1e6)
        if !roundTrips.isEmpty {
            let avg = roundTrips.reduce(0, +) / Double(roundTrips.count) * 1000
            line += String(format: ", round trip %.0f ms (max %.0f)", avg, (roundTrips.max() ?? 0) * 1000)
        }
        if let decodeMs = decodeMs { line += ", iPad decode \(decodeMs) ms" }
        return line
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
