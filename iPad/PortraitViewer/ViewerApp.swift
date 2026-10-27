import SwiftUI
import UIKit

/// Portrait Display's native viewer: shows the Mac's "Portrait iPad" display over the USB cable, and
/// sends touch and Pencil input back.
/// The Mac side (PortraitHost) finds the app through usbmuxd and connects; see
/// docs/native-viewer-design.md.
@main
struct ViewerApp: App {
    @Environment(\.scenePhase) private var phase
    private let controller = ViewerController()

    var body: some Scene {
        WindowGroup {
            ControllerView(controller: controller)
                .ignoresSafeArea()
                .persistentSystemOverlays(.hidden)
                .onChange(of: phase, initial: true) { _, now in
                    if now == .active { controller.becameActive() }
                }
        }
    }
}

private struct ControllerView: UIViewControllerRepresentable {
    let controller: ViewerController
    func makeUIViewController(context: Context) -> ViewerController { controller }
    func updateUIViewController(_ controller: ViewerController, context: Context) {}
}

final class ViewerController: UIViewController {
    private let link = LinkServer()
    private let video = VideoView()
    private let message = UILabel()
    private let overlay = UILabel()
    private var stats = ""
    // Counted per second for the overlay, like the web page's.
    private var frames = 0, bytes = 0, rate = 0, kbps = 0
    private var meter: Timer?
    private var hideOverlay: DispatchWorkItem?

    override func loadView() {
        view = video
        message.textColor = .white
        message.font = .preferredFont(forTextStyle: .title3)
        message.textAlignment = .center
        message.numberOfLines = 0
        overlay.textColor = .white
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        overlay.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        overlay.numberOfLines = 0
        overlay.isHidden = true
        for label in [message, overlay] {
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
        }
        NSLayoutConstraint.activate([
            message.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.8),
            overlay.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            overlay.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            overlay.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
        ])
        video.input.send = { [weak self] text in
            guard let self, self.video.hasPicture else { return }
            self.link.send(text)
        }
        video.input.onToggleOverlay = { [weak self] in self?.toggleOverlay() }

        link.onConnect = { [weak self] in self?.connected() }
        link.onDisconnect = { [weak self] in self?.disconnected() }
        link.onMessage = { [weak self] data, isText in self?.received(data, isText: isText) }
        link.onStatus = { [weak self] text in self?.message.text = text }
        video.onNeedKeyframe = { [weak self] in self?.link.send("key") }
        showWaiting()
        meter = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.rate = self.frames
            self.kbps = self.bytes * 8 / 1000
            self.frames = 0
            self.bytes = 0
            self.updateOverlay()
        }
    }

    func becameActive() {
        link.start()
    }

    private func connected() {
        message.text = "Connected. Starting the display…"
        UIApplication.shared.isIdleTimerDisabled = true
        link.send("hello native" + (VideoView.decodesHEVC ? " hevc" : ""))
    }

    private func disconnected() {
        video.clear()
        UIApplication.shared.isIdleTimerDisabled = false
        showWaiting()
    }

    private func showWaiting() {
        message.isHidden = false
        message.text = "Connect the USB cable and start Portrait Display on the Mac."
    }

    private func received(_ data: Data, isText: Bool) {
        if isText {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if let line = json["stats"] as? String {
                stats = line
                updateOverlay()
            } else {
                video.configure(json)
            }
            return
        }
        link.send("ack")   // every frame, shown or not: the Mac allows 4 unacknowledged
        frames += 1
        bytes += data.count
        let hadPicture = video.hasPicture
        video.show(data)
        if video.hasPicture, !hadPicture {
            message.isHidden = true
            showOverlayBriefly()   // as the web page does on connecting: what it is, and the gestures
        }
    }

    private func toggleOverlay() {
        hideOverlay?.cancel()
        overlay.isHidden.toggle()
        updateOverlay()
    }

    private func showOverlayBriefly() {
        overlay.isHidden = false
        updateOverlay()
        hideOverlay?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.overlay.isHidden = true }
        hideOverlay = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func updateOverlay() {
        guard !overlay.isHidden else { return }
        let size = view.bounds.size
        let w = Int(min(size.width, size.height)), h = Int(max(size.width, size.height))
        let stream = video.videoSize.map { "\(video.codecName) \(Int($0.width))×\(Int($0.height))" } ?? "–"
        let speed = kbps >= 1000 ? String(format: "%.1f Mbit/s", Double(kbps) / 1000) : "\(kbps) kbit/s"
        overlay.text = [
            "Connected over USB",
            "\(rate) updates/s · \(speed) · \(stream)",
            stats.isEmpty ? nil : stats,
            "This screen: \(w)×\(h) pt → in the Mac's Settings, set Size to \(w) × \(h)",
            "Pencil: point & drag · tap: click · double tap: double-click · drag: scroll",
            "Pinch: zoom · twist: rotate · 2-finger tap: right-click",
            "3-finger swipe: Mission Control / Spaces · 3-finger tap: hide this",
        ].compactMap { $0 }.map { " \($0) " }.joined(separator: "\n")
    }
}
