import Foundation
import Network

/// How the Mac and the iPad app find and trust each other.
public enum NativeLink {
    /// The app listens here on loopback; usbmuxd delivers the Mac's USB connection to it.
    public static let usbPort: UInt16 = 20809
    /// The app advertises this over Bonjour, on the peer-to-peer link, for direct Wi-Fi.
    public static let bonjourService = "_portraitdisplay._tcp"
}

/// One Mac's pairing: its stable ID (the TLS-PSK identity), its name for display, and the 256-bit key.
/// The Mac sends it to the app over USB, a trusted link; direct Wi-Fi then needs it on both sides.
public struct Pairing: Equatable {
    public let macID: String
    public let macName: String
    public let key: Data

    public init(macID: String, macName: String, key: Data) {
        self.macID = macID
        self.macName = macName
        self.key = key
    }

    /// `{"pair":"<base64 key>","id":"<mac id>","name":"<mac name>"}`, sent as a text message.
    public var message: Data {
        (try? JSONSerialization.data(withJSONObject: ["pair": key.base64EncodedString(), "id": macID, "name": macName])) ?? Data()
    }

    /// The pairing in a decoded text message, if it is one. Older Macs sent no ID or name.
    public init?(message json: [String: Any]) {
        guard let encoded = json["pair"] as? String, let key = Data(base64Encoded: encoded), key.count == 32 else { return nil }
        self.init(macID: json["id"] as? String ?? "PortraitDisplay", macName: json["name"] as? String ?? "Mac", key: key)
    }
}

/// TCP with TLS 1.2 PSK, allowed onto the peer-to-peer link. A device without a matching key can't
/// complete the handshake, so it can't receive the screen, and the stream is encrypted over the air.
public enum DirectWiFiTLS {
    /// The Mac (client) offers its own key; the iPad (listener) holds one key per paired Mac and the
    /// handshake picks the one whose identity the Mac offers.
    public static func parameters(keys: [(identity: String, key: Data)]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        for (identity, key) in keys {
            sec_protocol_options_add_pre_shared_key(options,
                                                    key.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData,
                                                    Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData)
        }
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
