import Foundation
import Network
import Security

/// The key a Mac sends over the USB cable to pair direct Wi-Fi (see Sources/PortraitHost/DirectWiFi.swift).
/// Kept in the Keychain; Wi-Fi connections use it as a TLS pre-shared key, so only that Mac can connect
/// and the stream is encrypted.
enum PairingKey {
    private static let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: "PortraitDisplay.directWiFi",
        kSecAttrAccount: "mac",
    ]

    static var stored: Data? {
        var result: CFTypeRef?
        var q = query
        q[kSecReturnData] = true
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Returns true if the key changed.
    @discardableResult
    static func store(_ key: Data) -> Bool {
        guard key.count == 32, key != stored else { return false }
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData] = key
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    /// TCP with TLS 1.2 PSK, the same as the Mac builds, allowed onto the peer-to-peer link.
    static func parameters(_ key: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        let identity = Data("PortraitDisplay".utf8)
        sec_protocol_options_add_pre_shared_key(options,
                                                key.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData,
                                                identity.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }
}
