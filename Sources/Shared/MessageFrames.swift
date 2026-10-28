import Foundation

/// The native iPad app's framing, over the USB tunnel and direct Wi-Fi alike:
/// `[u32 big-endian length of the rest][u8 kind: 0 text, 1 binary][payload]`.
public enum MessageFrames {
    /// Messages from the iPad are small (acks, input); the Mac uses this limit for what it receives.
    public static let maxFromIPad = 64 * 1024
    /// Frames from the Mac can be large keyframes; the iPad uses this limit.
    public static let maxFromMac = 64 << 20

    public static func frame(_ data: Data, isText: Bool) -> Data {
        var framed = Data(capacity: 5 + data.count)
        withUnsafeBytes(of: UInt32(1 + data.count).bigEndian) { framed.append(contentsOf: $0) }
        framed.append(isText ? 0 : 1)
        framed.append(data)
        return framed
    }

    /// Removes the complete messages at the front of `buffer` and returns them as (payload, isText);
    /// an incomplete message stays for the next call. Nil if the stream is broken: a zero length, or
    /// one over `maxLength`.
    public static func take(from buffer: inout Data, maxLength: Int) -> [(payload: Data, isText: Bool)]? {
        var messages: [(payload: Data, isText: Bool)] = []
        while buffer.count >= 5 {
            let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard length >= 1, length <= maxLength else { return nil }
            guard buffer.count >= 4 + length else { break }
            let start = buffer.startIndex
            messages.append((Data(buffer[(start + 5)..<(start + 4 + length)]), buffer[start + 4] == 0))
            buffer.removeSubrange(start..<(start + 4 + length))
        }
        return messages
    }
}
