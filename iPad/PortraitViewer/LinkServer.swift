import Foundation
import Network

/// Waits for the Mac on loopback port 20809, where usbmuxd delivers its connection through the USB
/// cable, and carries framed messages: `[u32 big-endian length of the rest][u8 kind: 0 text, 1 binary]
/// [payload]`. One connection at a time; a new one replaces the old. Everything runs on the main queue.
final class LinkServer {
    static let port: NWEndpoint.Port = 20809

    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onMessage: ((_ data: Data, _ isText: Bool) -> Void)?
    var onStatus: ((String) -> Void)?

    private var listener: NWListener?
    private var connection: NWConnection?
    private var pending = Data()

    /// Call whenever the app comes on screen: suspension in the background kills the listener.
    func start() {
        listener?.cancel()
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: Self.port)
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    self?.onStatus?("Couldn't listen for the Mac (\(error)). Retrying…")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.start() }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            onStatus?("Couldn't listen for the Mac (\(error)).")
        }
    }

    func send(_ data: Data, isText: Bool) {
        guard let connection else { return }
        var framed = Data(capacity: 5 + data.count)
        withUnsafeBytes(of: UInt32(1 + data.count).bigEndian) { framed.append(contentsOf: $0) }
        framed.append(isText ? 0 : 1)
        framed.append(data)
        connection.send(content: framed, completion: .idempotent)
    }

    func send(_ text: String) {
        send(Data(text.utf8), isText: true)
    }

    private func accept(_ new: NWConnection) {
        connection?.cancel()
        connection = new
        pending = Data()
        new.stateUpdateHandler = { [weak self, weak new] state in
            guard let self, let new, new === self.connection else { return }
            switch state {
            case .ready: self.onConnect?()
            case .failed, .cancelled: self.drop()
            default: break
            }
        }
        new.start(queue: .main)
        receive(on: new)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self, connection === self.connection else { return }
            if let data, !data.isEmpty { self.received(data) }
            if done || error != nil { self.drop(); return }
            self.receive(on: connection)
        }
    }

    private func received(_ data: Data) {
        pending.append(data)
        while pending.count >= 5 {
            let length = pending.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard length >= 1, length <= 64 << 20 else { drop(); return }
            guard pending.count >= 4 + length else { return }
            let start = pending.startIndex
            let isText = pending[start + 4] == 0
            let payload = Data(pending[(start + 5)..<(start + 4 + length)])
            pending.removeSubrange(start..<(start + 4 + length))
            onMessage?(payload, isText)
        }
    }

    private func drop() {
        guard let connection else { return }
        self.connection = nil
        connection.cancel()
        onDisconnect?()
    }
}
