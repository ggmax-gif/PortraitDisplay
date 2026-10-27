// Link spike, iPad side: echoes every byte back on two listeners. Loopback port 20808 is for the Mac
// over the USB cable (usbmuxd); the Bonjour service "_portraitecho._tcp", with peer-to-peer allowed,
// is for the Mac over direct Wi-Fi without the router. Mac side: Spike/link/rtt.swift.
// See docs/native-viewer-design.md.
import Network
import SwiftUI

@main
struct EchoApp: App {
    @StateObject private var echo = EchoServer()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Text("Link echo spike").font(.title)
                ForEach(echo.status.keys.sorted(), id: \.self) { label in
                    Text("\(label): \(echo.status[label] ?? "")").font(.body.monospaced())
                }
                Text("\(echo.bytes) bytes echoed").foregroundStyle(.secondary)
            }
            .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
            // Suspension in the background kills the listeners (the Bonjour one fails with
            // DefunctConnection), so start them afresh every time the app comes back on screen.
            .onChange(of: phase, initial: true) { _, now in
                if now == .active { echo.start() }
            }
        }
    }
}

final class EchoServer: ObservableObject {
    @Published var status: [String: String] = [:]
    @Published var bytes = 0
    private var listeners: [NWListener] = []
    private let queue = DispatchQueue(label: "echo")

    func start() {
        listeners.forEach { $0.cancel() }
        listeners = []
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true

        // USB: usbmuxd delivers the Mac's connection on loopback, so nothing on Wi-Fi reaches this one.
        let usb = NWParameters(tls: nil, tcp: tcp)
        usb.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 20808)
        usb.allowLocalEndpointReuse = true
        listen(usb, service: nil, label: "USB")

        // Direct Wi-Fi: advertised over Bonjour, including on the peer-to-peer link AirDrop uses.
        let wifi = NWParameters(tls: nil, tcp: tcp)
        wifi.includePeerToPeer = true
        listen(wifi, service: NWListener.Service(name: UIDevice.current.name, type: "_portraitecho._tcp"), label: "Wi-Fi")
    }

    private func listen(_ parameters: NWParameters, service: NWListener.Service?, label: String) {
        do {
            let listener = try NWListener(using: parameters)
            listener.service = service
            listener.stateUpdateHandler = { [weak self] state in
                self?.show(label, "listener \(state)")
                if case .failed = state {   // try again in a second
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.start() }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection, via: label) }
            listener.start(queue: queue)
            listeners.append(listener)
        } catch {
            show(label, "listener failed: \(error)")
        }
    }

    private func accept(_ connection: NWConnection, via label: String) {
        show(label, "Mac connected")
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.show(label, "Mac disconnected") }
            if case .failed(let error) = state { self?.show(label, "failed: \(error)"); connection.cancel() }
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

    private func show(_ label: String, _ text: String) {
        DispatchQueue.main.async { self.status[label] = text }
    }
}
