// USB spike, iPad side: listens on loopback port 20808 and echoes every byte back. The Mac reaches it
// through the cable via usbmuxd (Spike/usb/rtt.swift). See docs/usb-design.md.
import Network
import SwiftUI

@main
struct EchoApp: App {
    @StateObject private var echo = EchoServer()

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Text("USB echo spike").font(.title)
                Text(echo.status).font(.body.monospaced())
                Text("\(echo.bytes) bytes echoed").foregroundStyle(.secondary)
            }
            .onAppear {
                UIApplication.shared.isIdleTimerDisabled = true
                echo.start()
            }
        }
    }
}

final class EchoServer: ObservableObject {
    @Published var status = "starting"
    @Published var bytes = 0
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "echo")

    func start() {
        guard listener == nil else { return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        // usbmuxd delivers the Mac's connection on loopback, so nothing on Wi-Fi can reach this.
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 20808)
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in self?.show("listener: \(state)") }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            show("listener failed: \(error)")
        }
    }

    private func accept(_ connection: NWConnection) {
        show("Mac connected")
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.show("Mac disconnected") }
            if case .failed(let error) = state { self?.show("failed: \(error)"); connection.cancel() }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            if let data, !data.isEmpty {
                connection.send(content: data, completion: .idempotent)
                DispatchQueue.main.async { self?.bytes += data.count }
            }
            if done || error != nil { connection.cancel(); return }
            self?.receive(on: connection)
        }
    }

    private func show(_ text: String) {
        DispatchQueue.main.async { self.status = text }
    }
}
