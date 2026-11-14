import AppKit
import CoreImage.CIFilterBuiltins

/// Menu bar front end: starts and stops PortraitHost, shows the iPad link and the latest stats.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let host = HostProcess()
    private let hostStatus = HostStatus()
    private lazy var settingsWindow = SettingsWindowController(status: hostStatus)
    private var statusItem: NSStatusItem!
    private var qrWindow: NSWindow?
    private var renewal: RenewalNotifier?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.register()
        installMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "ipad", accessibilityDescription: "Portrait Display")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        hostStatus.restart = { [weak self] in self?.host.restart() }
        host.onChange = { [weak self] in self?.hostChanged() }
        host.onFailure = { [weak self] message in self?.showFailure(message) }
        host.onIPadSize = { [weak self] width, height in
            // Only with one iPad: two of different sizes would keep restarting each other.
            guard let self, self.host.viewers == 1, Settings.adoptIPadSize(width: width, height: height) else { return }
            self.host.restart()
        }
        if Bundle.main.bundleURL.pathExtension == "app" {
            let canRenew = Self.installScript != nil
            renewal = RenewalNotifier(canRenew: canRenew, onRenew: { [weak self] in self?.renewIPadApp() },
                                      onAlert: { [weak self] title, body in
                guard let self, self.alert(title, body, button: canRenew ? "Renew" : nil) else { return }
                self.renewIPadApp()
            })
        }
        host.onIPadExpires = { [weak self] expires in
            UserDefaults.standard.set(expires, forKey: Settings.Key.iPadAppExpires)
            self?.renewal?.update(expires: expires)
        }
        host.onIPadDevice = { UserDefaults.standard.set($0, forKey: Settings.Key.iPadDevice) }
        if let expires = UserDefaults.standard.object(forKey: Settings.Key.iPadAppExpires) as? Date {
            renewal?.update(expires: expires)
        }
        updateIcon()
        if Settings.startOnLaunch { host.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        host.stopAndWait()
    }

    /// Never shown (the app has no menu bar of its own), but its key equivalents are what make
    /// Cmd-C / Cmd-V / Cmd-A / Cmd-Z work in the Settings fields, and Cmd-W close the window.
    private func installMainMenu() {
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = NSMenu(title: title)
            items.forEach { item.submenu?.addItem($0) }
            return item
        }
        func entry(_ title: String, _ action: Selector, _ key: String, shift: Bool = false) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            if shift { item.keyEquivalentModifierMask = [.command, .shift] }
            return item
        }
        let main = NSMenu()
        main.addItem(submenu("Portrait Display", [
            entry("Quit Portrait Display", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(submenu("Edit", [
            entry("Undo", Selector(("undo:")), "z"),
            entry("Redo", Selector(("redo:")), "z", shift: true),
            .separator(),
            entry("Cut", #selector(NSText.cut(_:)), "x"),
            entry("Copy", #selector(NSText.copy(_:)), "c"),
            entry("Paste", #selector(NSText.paste(_:)), "v"),
            entry("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]))
        main.addItem(submenu("Window", [
            entry("Close", #selector(NSWindow.performClose(_:)), "w"),
        ]))
        NSApp.mainMenu = main
    }

    private func hostChanged() {
        updateIcon()
        if hostStatus.runningArguments != host.runningArguments { hostStatus.runningArguments = host.runningArguments }
        if menuIsOpen, let menu = statusItem.menu { refresh(menu) }
    }

    private func updateIcon() {
        statusItem.button?.appearsDisabled = host.state == .stopped
    }

    // MARK: Menu
    //
    // Built when it opens. While it stays open, host changes update the status and stats lines in
    // place; only a change in which items exist rebuilds it (rebuilding every 2 s for the stats would
    // drop the highlight on the item under the pointer).

    private var menuIsOpen = false
    private var builtShape: MenuShape?
    private weak var statusLine: NSMenuItem?
    private weak var statsLine: NSMenuItem?

    /// Which items the menu has; the texts can change without it.
    private struct MenuShape: Equatable {
        var stopped: Bool
        var urls: [String]
        var needsAccessibility: Bool
        var hasStats: Bool
    }

    private var shape: MenuShape {
        MenuShape(stopped: host.state == .stopped, urls: host.urls,
                  needsAccessibility: host.needsAccessibility, hasStats: host.stats != nil)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        build(menu)
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }

    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }

    private func refresh(_ menu: NSMenu) {
        guard shape == builtShape else { build(menu); return }
        statusLine?.title = statusText
        if let stats = host.stats { statsLine?.attributedTitle = small(stats) }
    }

    private func build(_ menu: NSMenu) {
        menu.removeAllItems()
        builtShape = shape
        let status = label(statusText)
        statusLine = status
        menu.addItem(status)
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
                let line = label(stats)
                line.attributedTitle = small(stats)
                statsLine = line
                menu.addItem(line)
            }
        }

        // Only once the native app has connected: Safari users have no app to expire.
        if let expires = UserDefaults.standard.object(forKey: Settings.Key.iPadAppExpires) as? Date {
            menu.addItem(.separator())
            let when = RelativeDateTimeFormatter().localizedString(for: expires, relativeTo: Date())
            menu.addItem(label(expires < Date() ? "iPad app expired \(when)" : "iPad app expires \(when)"))
            if Self.installScript != nil { menu.addItem(item("Renew iPad App", #selector(renewIPadApp))) }
        }

        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(showSettings), key: ","))
        menu.addItem(item("Show Log", #selector(showLog)))
        menu.addItem(item("Copy Diagnostics", #selector(copyDiagnostics)))
        if FileManager.default.fileExists(atPath: Self.pairingKeyURL.path) {
            menu.addItem(item("Unpair iPads…", #selector(unpair)))
        }
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
            case 0 where !host.displayOn: return "Ready – open the link on the iPad"
            case 0 where host.onDemand: return "On – iPad gone, display closes soon"
            case 0: return "On – waiting for the iPad"
            case 1: return "On – iPad connected" + (host.links.first.map { " (\($0))" } ?? "")
            default: return "On – \(host.viewers) iPads connected"
            }
        }
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func label(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func small(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
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

    @objc private func showSettings() {
        settingsWindow.show()
    }

    @objc private func showLog() {
        NSWorkspace.shared.open(HostProcess.logURL)
    }

    /// For a bug report: see `Diagnostics` for what goes in and what is kept out.
    @objc private func copyDiagnostics() {
        let defaults = UserDefaults.standard
        let info = Bundle.main.infoDictionary ?? [:]
        let expires = defaults.object(forKey: Settings.Key.iPadAppExpires) as? Date
        var facts = Diagnostics.machine()
        facts += [
            ("Portrait Display", "\(info["CFBundleShortVersionString"] as? String ?? "?") (build \(info["CFBundleVersion"] as? String ?? "?"))"),
            ("Host", host.state == .stopped ? "stopped" : "running with " + (host.runningArguments ?? []).joined(separator: " ")),
            ("iPads connected", host.viewers == 0 ? "none" : "\(host.viewers) (\(host.links.joined(separator: ", ")))"),
            ("Last iPad app", defaults.string(forKey: Settings.Key.iPadDevice) ?? "none seen yet"),
            ("iPad app expires", expires.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"),
        ]
        if host.needsAccessibility { facts.append(("Touch input", "needs Accessibility permission")) }
        let log = (try? String(contentsOf: HostProcess.logURL, encoding: .utf8)) ?? ""
        let excerpt = Diagnostics.excerpt(log: log, token: Diagnostics.savedToken())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Diagnostics.report(facts: facts, excerpt: excerpt), forType: .string)
        if alert("Diagnostics copied", "This Mac's model and macOS version, the settings, the last iPad app's model and "
                 + "\(excerpt.count) recent stats and connection lines from the log, without the link's key. "
                 + "Paste them into a GitHub issue.", button: "Open GitHub Issues") {
            NSWorkspace.shared.open(URL(string: "https://github.com/ggmax-gif/PortraitDisplay/issues/new")!)
        }
    }

    /// scripts/install-ipad.sh in the checkout this app was built from (make-app.sh records it).
    private static let installScript: URL? = {
        guard let source = Bundle.main.object(forInfoDictionaryKey: "PortraitDisplaySource") as? String else { return nil }
        let script = URL(fileURLWithPath: source).appendingPathComponent("scripts/install-ipad.sh")
        return FileManager.default.isExecutableFile(atPath: script.path) ? script : nil
    }()

    /// In Terminal, so the build's progress and any signing problem are visible.
    @objc private func renewIPadApp() {
        guard let script = Self.installScript,
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    /// The host's direct Wi-Fi key (`DirectWiFi.keyURL` in PortraitHost). Every paired iPad has a copy.
    private static let pairingKeyURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".portraitdisplay/direct-wifi.key")

    /// Deleting the key unpairs every iPad at once: the host makes a new one when it starts and gives
    /// it to the next iPad that connects over USB.
    @objc private func unpair() {
        guard alert("Unpair all iPads?", "They can no longer connect over direct Wi-Fi until they're connected "
                    + "with the USB cable once, which pairs them again.\n\nOn the iPad, Paired Macs lists "
                    + "the Macs it can connect to and can forget one.", button: "Unpair") else { return }
        do {
            try FileManager.default.removeItem(at: Self.pairingKeyURL)
        } catch {
            alert("Couldn't unpair", error.localizedDescription)
            return
        }
        host.restart()   // a running host still has the old key
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
