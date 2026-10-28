import Foundation
import Network
import Shared
import UIKit

/// Waits for the Mac on two listeners and carries framed messages: `[u32 big-endian length of the
/// rest][u8 kind: 0 text, 1 binary][payload]`.
/// - USB: loopback port 20809, where usbmuxd delivers the Mac's connection through the cable.
/// - Direct Wi-Fi, once paired: a Bonjour service on the peer-to-peer link, with TLS using the keys
///   paired Macs sent over USB (PairedMacs), so only they can connect.
/// One connection at a time; a new one replaces the old (so plugging in the cable takes over from
/// Wi-Fi). Everything runs on the main queue.
final class LinkServer {
    static let port = NWEndpoint.Port(rawValue: NativeLink.usbPort)!

    /// The link the Mac connected over: "USB" or "direct Wi-Fi".
    var onConnect: ((String) -> Void)?
    var onDisconnect: (() -> Void)?
    var onMessage: ((_ data: Data, _ isText: Bool) -> Void)?
    var onStatus: ((String) -> Void)?

    private var listeners: [NWListener] = []
    private var connection: NWConnection?
    private var pending = Data()

    /// Call whenever the app comes on screen (suspension in the background kills the listeners), and
    /// after pairing.
    func start() {
        listeners.forEach { $0.cancel() }
        listeners = []
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let usb = NWParameters(tls: nil, tcp: tcp)
        usb.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: Self.port)
        usb.allowLocalEndpointReuse = true
        listen(usb, service: nil, kind: "USB")
        let paired = PairedMacs.all
        if !paired.isEmpty {
            listen(DirectWiFiTLS.parameters(keys: paired.map { ($0.macID, $0.key) }),
                   service: NWListener.Service(name: UIDevice.current.name, type: NativeLink.bonjourService),
                   kind: "direct Wi-Fi")
        }
    }

    private func listen(_ parameters: NWParameters, service: NWListener.Service?, kind: String) {
        do {
            let listener = try NWListener(using: parameters)
            listener.service = service
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, self.listeners.contains(where: { $0 === listener }) else { return }
                if case .failed(let error) = state {
                    self.onStatus?("Couldn't listen for the Mac over \(kind) (\(error)). Retrying…")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.start() }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection, kind: kind) }
            listener.start(queue: .main)
            listeners.append(listener)
        } catch {
            onStatus?("Couldn't listen for the Mac over \(kind) (\(error)).")
        }
    }

    func send(_ data: Data, isText: Bool) {
        connection?.send(content: MessageFrames.frame(data, isText: isText), completion: .idempotent)
    }

    func send(_ text: String) {
        send(Data(text.utf8), isText: true)
    }

    private func accept(_ new: NWConnection, kind: String) {
        connection?.cancel()
        connection = new
        pending = Data()
        new.stateUpdateHandler = { [weak self, weak new] state in
            guard let self, let new, new === self.connection else { return }
            switch state {
            case .ready: self.onConnect?(kind)
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
        guard let messages = MessageFrames.take(from: &pending, maxLength: MessageFrames.maxFromMac) else { drop(); return }
        for (payload, isText) in messages { onMessage?(payload, isText) }
    }

    private func drop() {
        guard let connection else { return }
        self.connection = nil
        connection.cancel()
        onDisconnect?()
    }
}
