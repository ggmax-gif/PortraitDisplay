import Shared
import SwiftUI

/// The list of Macs paired for direct Wi-Fi, with Forget. A forgotten Mac pairs again the next time
/// it connects over the USB cable.
struct PairedMacsView: View {
    var onChange: () -> Void
    var onDone: () -> Void
    @State private var macs = PairedMacs.all

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if macs.isEmpty {
                        Text("None yet. Connect a Mac running Portrait Display over the USB cable once to pair it.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(macs, id: \.macID) { mac in
                        HStack {
                            Label(mac.macName, systemImage: "laptopcomputer")
                            Spacer()
                            Button("Forget", role: .destructive) {
                                PairedMacs.forget(mac.macID)
                                macs = PairedMacs.all
                                onChange()
                            }
                        }
                    }
                } footer: {
                    Text("A paired Mac can connect over direct Wi-Fi when the cable isn't plugged in. "
                         + "Connections are encrypted with a key only that Mac and this iPad have.")
                }
            }
            .navigationTitle("Paired Macs")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone) } }
        }
    }
}
