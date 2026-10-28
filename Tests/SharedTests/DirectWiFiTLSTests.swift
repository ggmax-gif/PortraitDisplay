import Network
import Shared
import XCTest

/// The direct Wi-Fi security, over loopback: an iPad-style listener that holds several Macs' keys
/// must accept a Mac whose key it has, picked by the Mac's ID, and refuse one whose key it doesn't.
final class DirectWiFiTLSTests: XCTestCase {
    private let queue = DispatchQueue(label: "tls-test")
    private let macA = Pairing(macID: "mac-a", macName: "A", key: Data(repeating: 0xA1, count: 32))
    private let macB = Pairing(macID: "mac-b", macName: "B", key: Data(repeating: 0xB2, count: 32))
    private let stranger = Pairing(macID: "mac-b", macName: "Stranger", key: Data(repeating: 0xEE, count: 32))

    /// Starts a listener with `paired` keys that echoes what it receives; returns it and its port.
    private func listener(paired: [Pairing]) throws -> (NWListener, NWEndpoint.Port) {
        let parameters = DirectWiFiTLS.parameters(keys: paired.map { ($0.macID, $0.key) })
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, _ in
                if let data { connection.send(content: data, completion: .idempotent) }
            }
        }
        listener.start(queue: queue)
        wait(for: [ready], timeout: 5)
        return (listener, try XCTUnwrap(listener.port))
    }

    /// Connects as `mac` and sends a ping; returns the echo, or nil if the handshake failed.
    private func exchange(as mac: Pairing, port: NWEndpoint.Port) -> Data? {
        let connection = NWConnection(host: "127.0.0.1", port: port, using: DirectWiFiTLS.parameters(keys: [(mac.macID, mac.key)]))
        let done = expectation(description: "exchange")
        var echo: Data?
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: Data("ping".utf8), completion: .idempotent)
                connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, _, _ in
                    echo = data
                    done.fulfill()
                }
            case .failed, .waiting:
                done.fulfill()
            default:
                break
            }
        }
        connection.start(queue: queue)
        wait(for: [done], timeout: 10)
        connection.cancel()
        return echo
    }

    func testAPairedMacConnectsWhicheverOfSeveralKeysIsItsOwn() throws {
        let (listener, port) = try listener(paired: [macA, macB])
        defer { listener.cancel() }
        XCTAssertEqual(exchange(as: macA, port: port), Data("ping".utf8))
        XCTAssertEqual(exchange(as: macB, port: port), Data("ping".utf8))
    }

    func testAnUnpairedKeyCannotConnectEvenWithAKnownID() throws {
        let (listener, port) = try listener(paired: [macA, macB])
        defer { listener.cancel() }
        XCTAssertNil(exchange(as: stranger, port: port))
    }

    func testPairingMessageRoundTrips() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: macA.message) as? [String: Any])
        XCTAssertEqual(Pairing(message: json), macA)
        XCTAssertNil(Pairing(message: ["pair": Data(count: 8).base64EncodedString()]))   // keys are 32 bytes
        XCTAssertNil(Pairing(message: ["stats": "…"]))
    }
}
