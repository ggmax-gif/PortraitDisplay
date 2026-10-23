import AppKit
import ServiceManagement
import SwiftUI

/// What the settings window needs from the running host. The app delegate keeps it current.
final class HostStatus: ObservableObject {
    @Published var runningArguments: [String]?   // the options the host was started with; nil while stopped
    var restart: () -> Void = {}
}

/// Launch at Login lives in SMAppService, not UserDefaults. (An object rather than @State: the
/// Command Line Tools' Swift has no SwiftUI macro plugin, and @State is a macro in this SDK.)
final class LoginItem: ObservableObject {
    @Published private(set) var enabled = SMAppService.mainApp.status == .enabled
    @Published private(set) var error: String?

    /// It can also be changed in System Settings → General → Login Items.
    func refresh() {
        enabled = SMAppService.mainApp.status == .enabled
        error = nil
    }

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = "Couldn't change it: \(error.localizedDescription)"
        }
        enabled = SMAppService.mainApp.status == .enabled
    }
}

/// Edits save straight away; a running host only picks them up when it restarts, so the window
/// offers that whenever the saved settings differ from what it was started with.
struct SettingsView: View {
    @ObservedObject var status: HostStatus
    @ObservedObject var login: LoginItem

    @AppStorage(Settings.Key.width) private var width = 1024
    @AppStorage(Settings.Key.height) private var height = 1334
    @AppStorage(Settings.Key.hiDPI) private var hiDPI = true
    @AppStorage(Settings.Key.fps) private var fps = 60
    @AppStorage(Settings.Key.codec) private var codec = "h264"
    @AppStorage(Settings.Key.bitrate) private var bitrate = 20.0
    @AppStorage(Settings.Key.scale) private var scale = 2.0
    @AppStorage(Settings.Key.onDemand) private var onDemand = true
    @AppStorage(Settings.Key.input) private var input = true
    @AppStorage(Settings.Key.startOnLaunch) private var startOnLaunch = false
    @AppStorage(Settings.Key.port) private var port = 8080

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Display") {
                    LabeledContent("Size") {
                        HStack(spacing: 4) {
                            NumberField(value: $width, range: Settings.sizeRange).frame(width: 64)
                            Text("×")
                            NumberField(value: $height, range: Settings.sizeRange).frame(width: 64)
                            Text("pt")
                        }
                    }
                    Text("The iPad overlay (three-finger tap) shows the size that fits it exactly.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Retina", isOn: $hiDPI)
                    Picker("Frame rate", selection: $fps) {
                        ForEach(Settings.fpsChoices, id: \.self) { Text("\($0) fps").tag($0) }
                    }
                }
                Section("Video") {
                    Picker("Codec", selection: $codec) {
                        Text("H.264 – sharpest text").tag("h264")
                        Text("HEVC – less data while moving").tag("hevc")
                    }
                    LabeledContent("Bitrate cap") {
                        HStack {
                            // Rounded here rather than with `step`, which draws a tick per Mbit/s.
                            Slider(value: Binding(get: { bitrate }, set: { bitrate = $0.rounded() }),
                                   in: Settings.bitrateRange)
                            Text("\(Int(bitrate)) Mbit/s").monospacedDigit().frame(width: 76, alignment: .trailing)
                        }
                    }
                    Picker("Stream resolution", selection: $scale) {
                        Text("Full").tag(2.0)
                        Text("Three quarters").tag(1.5)
                        Text("Half").tag(1.0)
                    }
                }
                Section("Behaviour") {
                    Toggle("Show the display only while an iPad is connected", isOn: $onDemand)
                    Toggle("Touch and Pencil control the Mac", isOn: $input)
                    Toggle("Start when the app opens", isOn: $startOnLaunch)
                    Toggle("Launch at login", isOn: Binding(get: { login.enabled }, set: login.set))
                    if let error = login.error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                Section("Network") {
                    LabeledContent("Port") {
                        HStack(spacing: 4) {
                            NumberField(value: $port, range: Settings.portRange).frame(width: 64)
                            let first = min(max(port, Settings.portRange.lowerBound), Settings.portRange.upperBound)
                            Text("(uses \(String(first))–\(String(first + 2)))").foregroundStyle(.secondary)
                        }
                    }
                    Text("Changing it breaks the iPad's Home Screen icon: open the new link and add it again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Restore Defaults") { Settings.restoreDefaults() }
                Spacer()
                if needsRestart {
                    Text("Changes apply after a restart.").foregroundStyle(.secondary)
                    // No Return shortcut: Return in a number field would restart the host mid-edit.
                    Button("Restart Now") {
                        NSApp.keyWindow?.makeFirstResponder(nil)   // commits a number still being typed
                        status.restart()
                    }
                }
            }
            .padding([.horizontal, .bottom], 20)
            .padding(.top, 8)
        }
        .frame(width: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Reads UserDefaults, which every @AppStorage change above already re-renders for.
    private var needsRestart: Bool {
        guard let running = status.runningArguments else { return false }
        return Settings.hostArguments != running
    }
}

/// A whole-number field that commits when editing ends (Return, Tab, clicking elsewhere, closing the
/// window), clamped to `range`. Not SwiftUI's TextField: on this macOS that writes its binding on every
/// keystroke, so clamping there turned a typed 820 into 4000.
private struct NumberField: NSViewRepresentable {
    @Binding var value: Int
    let range: ClosedRange<Int>

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: String(value))
        field.alignment = .right
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.owner = self
        if field.currentEditor() == nil { field.stringValue = String(value) }   // not while it's being typed in
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var owner: NumberField
        init(_ owner: NumberField) { self.owner = owner }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            // Text that isn't a whole number (or overflows Int) keeps the old value.
            let typed = Int(field.stringValue.trimmingCharacters(in: .whitespaces)) ?? owner.value
            let clamped = min(max(typed, owner.range.lowerBound), owner.range.upperBound)
            field.stringValue = String(clamped)
            if clamped != owner.value { owner.value = clamped }
        }
    }
}

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let status: HostStatus
    private let login = LoginItem()

    init(status: HostStatus) {
        self.status = status
    }

    func show() {
        if window == nil {
            let controller = NSHostingController(rootView: SettingsView(status: status, login: login))
            controller.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: controller)
            window.title = "Portrait Display Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        login.refresh()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.makeFirstResponder(nil)   // saves a number still being typed
    }
}
