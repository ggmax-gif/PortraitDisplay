import AppKit
import CoreImage.CIFilterBuiltins
import ServiceManagement

/// Menu bar front end: starts and stops PortraitHost, shows the iPad link and the latest stats.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let host = HostProcess()
    private var statusItem: NSStatusItem!
    private var qrWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "ipad", accessibilityDescription: "Portrait Display")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        host.onChange = { [weak self] in self?.updateIcon() }
        host.onFailure = { [weak self] message in self?.showFailure(message) }
        updateIcon()
        // `defaults write com.danielfung.PortraitDisplay startOnLaunch -bool YES`, e.g. with Launch at Login.
        if UserDefaults.standard.bool(forKey: "startOnLaunch") { host.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        host.stopAndWait()
    }

    private func updateIcon() {
        statusItem.button?.appearsDisabled = host.state == .stopped
    }

    // MARK: Menu (rebuilt each time it opens)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(label(statusText))
        if host.state == .stopped {
            menu.addItem(item("Start", #selector(start)))
        } else {
            menu.addItem(item("Stop", #selector(stop)))
        }

        if host.state != .stopped {
            if !host.urls.isEmpty { menu.addItem(.separator()) }
            for url in host.urls {
                let ip = URL(string: url)?.host ?? url
                let copy = item("Copy iPad Link (\(ip))", #selector(copyLink(_:)))
                copy.representedObject = url
                menu.addItem(copy)
            }
            if !host.urls.isEmpty { menu.addItem(item("Show QR Code for iPad…", #selector(showQRCode))) }
            if host.needsAccessibility {
                menu.addItem(item("Touch Input Needs Accessibility Permission…", #selector(openAccessibility)))
            }
            if let stats = host.stats {
                menu.addItem(.separator())
                menu.addItem(label(stats, small: true))
            }
        }

        menu.addItem(.separator())
        menu.addItem(item("Show Log", #selector(showLog)))
        let login = item("Launch at Login", #selector(toggleLaunchAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Portrait Display", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    private var statusText: String {
        switch host.state {
        case .stopped: return "Portrait Display: Off"
        case .starting: return "Starting…"
        case .running:
            switch host.viewers {
            case 0: return "On – waiting for the iPad"
            case 1: return "On – iPad connected"
            default: return "On – \(host.viewers) iPads connected"
            }
        }
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func label(_ text: String, small: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        if small {
            item.attributedTitle = NSAttributedString(string: text, attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        }
        item.isEnabled = false
        return item
    }

    // MARK: Actions

    @objc private func start() { host.start() }

    @objc private func stop() {
        host.stop()
        qrWindow?.close()
    }

    @objc private func copyLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    /// Scan with the iPad camera instead of typing the link.
    @objc private func showQRCode() {
        guard let url = host.urls.first else { return }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.utf8)
        // Integer scale on the CIImage keeps the modules sharp; NSImageView would blur a small one.
        guard let code = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return }
        let rep = NSCIImageRep(ciImage: code)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)

        let imageView = NSImageView(image: image)
        let caption = NSTextField(labelWithString: url)
        caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        caption.isSelectable = true
        let stack = NSStackView(views: [imageView, caption])
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)

        qrWindow?.close()
        let window = NSPanel(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Open on the iPad"
        window.contentView = stack
        window.isReleasedWhenClosed = false
        window.center()
        qrWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func openAccessibility() {
        openSettings("Privacy_Accessibility")
    }

    @objc private func showLog() {
        NSWorkspace.shared.open(HostProcess.logURL)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert("Couldn't change Launch at Login", error.localizedDescription)
        }
    }

    private func showFailure(_ message: String) {
        qrWindow?.close()
        if message.hasPrefix("capture:") {
            if alert("Portrait Display can't record the screen",
                     "Turn on Portrait Display in System Settings → Privacy & Security → Screen & System "
                     + "Audio Recording, then choose Start again.\n\n(\(message))", button: "Open Settings") {
                openSettings("Privacy_ScreenCapture")
            }
        } else {
            alert("Portrait Display stopped", message + "\n\nShow Log in the menu has the full output.")
        }
    }

    /// Returns true if the extra button was chosen.
    @discardableResult
    private func alert(_ title: String, _ text: String, button: String? = nil) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        if let button {
            alert.addButton(withTitle: button)
            alert.addButton(withTitle: "Cancel")
        }
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn && button != nil
    }

    private func openSettings(_ pane: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
        NSWorkspace.shared.open(url)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
