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

    override func loadView() {
        view = video
        message.textColor = .white
        message.font = .preferredFont(forTextStyle: .title3)
        message.textAlignment = .center
        message.numberOfLines = 0
        overlay.textColor = .white
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        overlay.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
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
        video.show(data)
        if video.hasPicture { message.isHidden = true }
    }

    private func toggleOverlay() {
        overlay.isHidden.toggle()
        updateOverlay()
    }

    private func updateOverlay() {
        guard !overlay.isHidden else { return }
        let size = view.bounds.size
        overlay.text = " USB · \(Int(size.width))×\(Int(size.height)) pt \n \(stats.isEmpty ? "–" : stats) "
    }
}
