import Foundation
import Network

/// How one viewer's messages travel. Safari uses a secure WebSocket; the native iPad app uses a plain
/// byte stream through the USB cable (usbmuxd), with each message framed as
/// `[u32 big-endian length of the rest][u8 kind: 0 text, 1 binary][payload]`.
/// Everything is called on the server's queue.
protocol ViewerLink: AnyObject {
    /// For log lines: an IP address, or "USB".
    var name: String { get }
    /// How the iPad is connected, for the menu bar app: "USB" or "Wi-Fi".
    var kind: String { get }
    /// True when reaching the link already proves who it is (the cable needs physical access and a
    /// trusted pairing), so `hello` needs no token.
    var trusted: Bool { get }
    func start(on queue: DispatchQueue, onMessage: @escaping (_ data: Data, _ isText: Bool) -> Void,
               onClose: @escaping () -> Void)
    func send(_ data: Data, isText: Bool)
    func close()
}

/// The Safari viewer page's secure WebSocket.
final class WebSocketLink: ViewerLink {
    let connection: NWConnection
    private let logTLSFailure: (NWConnection.State) -> Void
    private var onClose: (() -> Void)?

    init(connection: NWConnection, logTLSFailure: @escaping (NWConnection.State) -> Void) {
        self.connection = connection
        self.logTLSFailure = logTLSFailure
    }

    var name: String {
        if case let .hostPort(host, _) = connection.endpoint { return "\(host)" }
        return "\(connection.endpoint)"
    }

    var trusted: Bool { false }
    var kind: String { "Wi-Fi" }

    func start(on queue: DispatchQueue, onMessage: @escaping (Data, Bool) -> Void, onClose: @escaping () -> Void) {
        self.onClose = onClose
        connection.stateUpdateHandler = { [weak self] state in
            self?.logTLSFailure(state)
            switch state {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        connection.start(queue: queue)
        receive(onMessage)
    }

    private func receive(_ onMessage: @escaping (Data, Bool) -> Void) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, self.onClose != nil else { return }
            if error != nil { self.finish(); return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .close { self.finish(); return }
            if let data { onMessage(data, metadata?.opcode != .binary) }
            self.receive(onMessage)
        }
    }

    func send(_ data: Data, isText: Bool) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: isText ? .text : .binary)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true,
                        completion: .contentProcessed { [weak self] error in
                            if error != nil { self?.finish() }
                        })
    }

    func close() {
        connection.cancel()
    }

    private func finish() {
        guard let onClose else { return }
        self.onClose = nil
        connection.cancel()
        onClose()
    }
}

/// The native app's framing: `[u32 big-endian length of the rest][u8 kind: 0 text, 1 binary][payload]`.
enum MessageFrames {
    /// Messages from the iPad are small (acks, input); anything bigger is a broken stream.
    static let maxIncoming = 64 * 1024

    static func frame(_ data: Data, isText: Bool) -> Data {
        var framed = Data(capacity: 5 + data.count)
        withUnsafeBytes(of: UInt32(1 + data.count).bigEndian) { framed.append(contentsOf: $0) }
        framed.append(isText ? 0 : 1)
        framed.append(data)
        return framed
    }

    /// Removes the complete messages at the front of `buffer`; nil if the stream is broken.
    static func take(from buffer: inout Data) -> [(Data, Bool)]? {
        var messages: [(Data, Bool)] = []
        while buffer.count >= 5 {
            let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard length >= 1, length <= maxIncoming else { return nil }
            guard buffer.count >= 4 + length else { break }
            let start = buffer.startIndex
            messages.append((Data(buffer[(start + 5)..<(start + 4 + length)]), buffer[start + 4] == 0))
            buffer.removeSubrange(start..<(start + 4 + length))
        }
        return messages
    }
}

/// A connected stream socket (the usbmuxd tunnel to the iPad app) carrying framed messages.
final class SocketStreamLink: ViewerLink {
    let name: String
    var trusted: Bool { true }
    var kind: String { "USB" }
    private let fd: Int32
    private var channel: DispatchIO?
    private var queue: DispatchQueue?
    private var pending = Data()
    private var onClose: (() -> Void)?
    private let onFinish: () -> Void

    /// `onFinish` runs once the link has closed, whichever side closed it.
    init(fd: Int32, name: String, onFinish: @escaping () -> Void) {
        self.fd = fd
        self.name = name
        self.onFinish = onFinish
    }

    func start(on queue: DispatchQueue, onMessage: @escaping (Data, Bool) -> Void, onClose: @escaping () -> Void) {
        self.queue = queue
        self.onClose = onClose
        let fd = self.fd
        let channel = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue) { _ in Darwin.close(fd) }
        channel.setLimit(lowWater: 1)
        self.channel = channel
        channel.read(offset: 0, length: Int.max, queue: queue) { [weak self] done, data, error in
            guard let self, self.onClose != nil else { return }
            if let data, !data.isEmpty { self.received(Data(data), onMessage) }
            if done || error != 0 { self.finish() }
        }
    }

    private func received(_ data: Data, _ onMessage: (Data, Bool) -> Void) {
        pending.append(data)
        guard let messages = MessageFrames.take(from: &pending) else { finish(); return }
        for (payload, isText) in messages where onClose != nil { onMessage(payload, isText) }
    }

    func send(_ data: Data, isText: Bool) {
        guard let channel, let queue else { return }
        let bytes = MessageFrames.frame(data, isText: isText).withUnsafeBytes { DispatchData(bytes: $0) }
        channel.write(offset: 0, data: bytes, queue: queue) { [weak self] done, _, error in
            if done && error != 0 { self?.finish() }
        }
    }

    func close() {
        finish()
    }

    private func finish() {
        guard let onClose else { return }
        self.onClose = nil
        channel?.close(flags: .stop)
        channel = nil
        onClose()
        onFinish()
    }
}

/// The native iPad app over direct peer-to-peer Wi-Fi: framed messages over an `NWConnection` that
/// is already encrypted and authenticated with the pairing key (TLS-PSK, see `DirectWiFi`).
final class ConnectionStreamLink: ViewerLink {
    let name = "direct Wi-Fi"
    var trusted: Bool { true }   // the TLS handshake only succeeds with the paired key
    var kind: String { "direct Wi-Fi" }
    private let connection: NWConnection
    private var queue: DispatchQueue?
    private var pending = Data()
    private var onClose: (() -> Void)?
    private let onFinish: () -> Void

    /// `connection` must already be ready. `onFinish` runs once the link has closed.
    init(connection: NWConnection, onFinish: @escaping () -> Void) {
        self.connection = connection
        self.onFinish = onFinish
    }

    func start(on queue: DispatchQueue, onMessage: @escaping (Data, Bool) -> Void, onClose: @escaping () -> Void) {
        self.onClose = onClose
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: queue.async { self?.finish() }
            default: break
            }
        }
        self.queue = queue
        receive(on: queue, onMessage)
    }

    private func receive(on queue: DispatchQueue, _ onMessage: @escaping (Data, Bool) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            queue.async {
                guard let self, self.onClose != nil else { return }
                if let data, !data.isEmpty {
                    self.pending.append(data)
                    guard let messages = MessageFrames.take(from: &self.pending) else { self.finish(); return }
                    for (payload, isText) in messages where self.onClose != nil { onMessage(payload, isText) }
                }
                if done || error != nil { self.finish(); return }
                self.receive(on: queue, onMessage)
            }
        }
    }

    func send(_ data: Data, isText: Bool) {
        connection.send(content: MessageFrames.frame(data, isText: isText), completion: .contentProcessed { [weak self] error in
            guard error != nil else { return }
            self?.queue?.async { self?.finish() }   // completions run on the connection's queue
        })
    }

    func close() {
        finish()
    }

    private func finish() {
        guard let onClose else { return }
        self.onClose = nil
        connection.cancel()
        onClose()
        onFinish()
    }
}
