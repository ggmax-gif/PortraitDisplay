import Foundation
import Network

/// How one viewer's messages travel. Safari uses a secure WebSocket; the native iPad app uses a plain
/// byte stream through the USB cable (usbmuxd), with each message framed as
/// `[u32 big-endian length of the rest][u8 kind: 0 text, 1 binary][payload]`.
/// Everything is called on the server's queue.
protocol ViewerLink: AnyObject {
    /// For log lines: an IP address, or "USB".
    var name: String { get }
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

/// A connected stream socket (the usbmuxd tunnel to the iPad app) carrying framed messages.
final class SocketStreamLink: ViewerLink {
    /// Messages from the iPad are small (acks, input); anything bigger is a broken stream.
    private static let maxIncoming = 64 * 1024

    let name: String
    var trusted: Bool { true }
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
        while pending.count >= 5 {
            let length = pending.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard length >= 1, length <= Self.maxIncoming else { finish(); return }
            guard pending.count >= 4 + length else { return }
            let start = pending.startIndex
            let isText = pending[start + 4] == 0
            let payload = Data(pending[(start + 5)..<(start + 4 + length)])
            pending.removeSubrange(start..<(start + 4 + length))
            onMessage(payload, isText)
            if onClose == nil { return }   // closed while handling
        }
    }

    func send(_ data: Data, isText: Bool) {
        guard let channel, let queue else { return }
        var framed = Data(capacity: 5 + data.count)
        withUnsafeBytes(of: UInt32(1 + data.count).bigEndian) { framed.append(contentsOf: $0) }
        framed.append(isText ? 0 : 1)
        framed.append(data)
        let bytes = framed.withUnsafeBytes { DispatchData(bytes: $0) }
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
