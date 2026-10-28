import Shared
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
    private let pairedButton = UIButton(configuration: .gray())
    private var stats = ""
    private var linkKind = "USB"
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
        pairedButton.configuration?.title = "Paired Macs"
        pairedButton.configuration?.image = UIImage(systemName: "laptopcomputer")
        pairedButton.configuration?.imagePadding = 6
        pairedButton.addAction(UIAction { [weak self] _ in self?.showPairedMacs() }, for: .primaryActionTriggered)
        for subview in [message, overlay, pairedButton] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            message.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.8),
            overlay.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            overlay.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            overlay.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            pairedButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pairedButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])
        PairedMacs.removeLegacy()
        video.input.send = { [weak self] text in
            guard let self, self.video.hasPicture else { return }
            self.link.send(text)
        }
        video.input.onToggleOverlay = { [weak self] in self?.toggleOverlay() }

        link.onConnect = { [weak self] kind in self?.connected(over: kind) }
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

    private func connected(over kind: String) {
        linkKind = kind
        message.text = "Connected over \(kind). Starting the display…"
        UIApplication.shared.isIdleTimerDisabled = true
        // The screen size lets the Mac size its virtual display to match (Settings → Match the iPad
        // app's screen size). The screen rather than the window, so a Stage Manager window doesn't shrink it.
        let size = view.window?.windowScene?.screen.bounds.size ?? view.bounds.size
        let w = Int(min(size.width, size.height)), h = Int(max(size.width, size.height))
        let expires = Self.expires.map { " expires=\(Int($0.timeIntervalSince1970))" } ?? ""
        link.send("hello native" + (VideoView.decodesHEVC ? " hevc" : "") + " size=\(w)x\(h)" + expires)
    }

    private func disconnected() {
        video.clear()
        UIApplication.shared.isIdleTimerDisabled = false
        showWaiting()
    }

    private func showWaiting() {
        message.isHidden = false
        pairedButton.isHidden = false
        var text = PairedMacs.all.isEmpty
            ? "Connect the USB cable and start Portrait Display on the Mac."
            : "Start Portrait Display on the Mac. It connects over the USB cable, or directly over Wi-Fi when the cable isn't plugged in."
        if let expires = Self.expires, expires.timeIntervalSinceNow < 2 * 86400 {
            let when = RelativeDateTimeFormatter().localizedString(for: expires, relativeTo: Date())
            text += "\n\nThis install stops opening \(when). Reinstall it from the Mac: Portrait Display menu → Reinstall iPad App."
        }
        message.text = text
    }

    /// When this install stops launching: its provisioning profile's expiry, 7 days after installing
    /// with a free Apple account (a year with a paid one). The Mac's menu shows it too.
    private static let expires: Date? = {
        // The profile is a signed CMS message with the plist inside as plain XML.
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound],
                                                                      format: nil) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }()

    private func received(_ data: Data, isText: Bool) {
        if isText {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if let line = json["stats"] as? String {
                stats = line
                updateOverlay()
            } else if let pairing = Pairing(message: json) {
                // Sent over USB only: lets this Mac connect over direct Wi-Fi from now on.
                if PairedMacs.save(pairing) { link.start() }
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
            pairedButton.isHidden = true
            showOverlayBriefly()   // as the web page does on connecting: what it is, and the gestures
        }
    }

    private func showPairedMacs() {
        var sheet: UIViewController?
        let list = PairedMacsView(onChange: { [weak self] in self?.link.start() },
                                  onDone: { sheet?.dismiss(animated: true) })
        sheet = UIHostingController(rootView: list)
        present(sheet!, animated: true)
    }

    private func toggleOverlay() {
        hideOverlay?.cancel()
        overlay.isHidden.toggle()
        if video.hasPicture { pairedButton.isHidden = overlay.isHidden }
        updateOverlay()
    }

    private func showOverlayBriefly() {
        overlay.isHidden = false
        pairedButton.isHidden = false
        updateOverlay()
        hideOverlay?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.overlay.isHidden = true
            if self?.video.hasPicture == true { self?.pairedButton.isHidden = true }
        }
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
            "Connected over \(linkKind)",
            "\(rate) updates/s · \(speed) · \(stream)",
            stats.isEmpty ? nil : stats,
            "This screen: \(w)×\(h) pt → in the Mac's Settings, set Size to \(w) × \(h)",
            "Pencil: point & drag · tap: click · double tap: double-click · drag: scroll",
            "Pinch: zoom · twist: rotate · 2-finger tap: right-click",
            "3-finger swipe: Mission Control / Spaces · 3-finger tap: hide this",
        ].compactMap { $0 }.map { " \($0) " }.joined(separator: "\n")
    }
}
