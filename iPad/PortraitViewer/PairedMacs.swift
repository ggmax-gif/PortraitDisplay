import Foundation
import Security
import Shared

/// The Macs paired for direct Wi-Fi, one Keychain item each (account = the Mac's ID, label = its
/// name, data = its key). A Mac pairs by connecting over the USB cable; pairing again replaces its
/// entry. The Wi-Fi listener offers every stored key, and TLS picks the one the Mac's ID names.
enum PairedMacs {
    private static let service = "PortraitDisplay.pairedMacs"

    static var all: [Pairing] {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecMatchLimit: kSecMatchLimitAll, kSecReturnAttributes: true, kSecReturnData: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[CFString: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item[kSecAttrAccount] as? String, let key = item[kSecValueData] as? Data, key.count == 32 else { return nil }
            return Pairing(macID: id, macName: item[kSecAttrLabel] as? String ?? "Mac", key: key)
        }.sorted { $0.macName < $1.macName }
    }

    /// Returns true if anything changed.
    @discardableResult
    static func save(_ pairing: Pairing) -> Bool {
        guard !all.contains(pairing) else { return false }
        forget(pairing.macID)
        let item: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                     kSecAttrAccount: pairing.macID, kSecAttrLabel: pairing.macName,
                                     kSecValueData: pairing.key,
                                     kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func forget(_ macID: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: macID] as CFDictionary)
    }

    /// The first version kept a single key under another name; Macs now pair with an ID, so it's unused.
    static func removeLegacy() {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: "PortraitDisplay.directWiFi"] as CFDictionary)
    }
}
