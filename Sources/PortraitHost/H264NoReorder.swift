import Foundation

/// VideoToolbox's SPS has no `bitstream_restriction`, so a spec-following decoder must assume
/// frames may be reordered and holds back up to MaxDpbFrames of output (7 at 1640×2360, level 5.0).
/// On a still screen the last change would then never appear. This rewrites the SPS inside the
/// avcC record to declare `max_num_reorder_frames = 0`, which is true since B-frames are off.
enum H264NoReorder {
    /// Returns the patched avcC, or nil if the SPS uses something this parser doesn't handle.
    static func patch(avcC: Data) -> Data? {
        let bytes = [UInt8](avcC)
        guard bytes.count > 6 else { return nil }
        var out = Array(bytes[0..<6])
        var i = 6
        for _ in 0..<Int(bytes[5] & 0x1F) {
            guard i + 2 <= bytes.count else { return nil }
            let length = Int(bytes[i]) << 8 | Int(bytes[i + 1])
            guard i + 2 + length <= bytes.count, length > 1 else { return nil }
            let nal = Array(bytes[(i + 2)..<(i + 2 + length)])
            guard let patched = patchSPS(nal) else { return nil }
            out += [UInt8(patched.count >> 8), UInt8(patched.count & 0xFF)] + patched
            i += 2 + length
        }
        out += bytes[i...]   // PPS entries and High-profile trailer, unchanged
        return Data(out)
    }

    private static func patchSPS(_ nal: [UInt8]) -> [UInt8]? {
        var r = BitReader(removeEmulationPrevention(Array(nal.dropFirst())))
        let profile = r.u(8)
        r.skip(16)                                   // constraint flags, level_idc
        _ = r.ue()                                   // seq_parameter_set_id
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            let chromaFormat = r.ue()
            if chromaFormat == 3 { r.skip(1) }
            _ = r.ue(); _ = r.ue(); r.skip(1)        // bit depths, qpprime_y_zero_transform_bypass
            if r.u(1) == 1 {                         // seq_scaling_matrix_present_flag
                for list in 0..<(chromaFormat == 3 ? 12 : 8) where r.u(1) == 1 {
                    var last = 8, next = 8
                    for _ in 0..<(list < 6 ? 16 : 64) {
                        if next != 0 { next = (last + r.se() + 256) % 256 }
                        if next != 0 { last = next }
                    }
                }
            }
        }
        _ = r.ue()                                   // log2_max_frame_num_minus4
        switch r.ue() {                              // pic_order_cnt_type
        case 0: _ = r.ue()
        case 1:
            r.skip(1); _ = r.se(); _ = r.se()
            for _ in 0..<r.ue() { _ = r.se() }
        default: break
        }
        let maxRefFrames = r.ue()
        r.skip(1); _ = r.ue(); _ = r.ue()            // gaps flag, width, height in macroblocks
        if r.u(1) == 0 { r.skip(1) }                 // frame_mbs_only_flag, mb_adaptive_frame_field
        r.skip(1)                                    // direct_8x8_inference_flag
        if r.u(1) == 1 { for _ in 0..<4 { _ = r.ue() } }   // frame cropping

        var w = BitWriter()
        let vuiFlagAt = r.position
        if r.u(1) == 0 {
            // No VUI yet: write one whose only content is the restriction.
            w.copy(r.data, bits: vuiFlagAt)
            w.put(1, bits: 1)
            w.put(0, bits: 8)                        // aspect, overscan, signal, chroma loc, timing, hrd×2, pic_struct
        } else {
            if r.u(1) == 1 { if r.u(8) == 255 { r.skip(32) } }        // aspect_ratio_info
            if r.u(1) == 1 { r.skip(1) }                               // overscan_info
            if r.u(1) == 1 { r.skip(4); if r.u(1) == 1 { r.skip(24) } } // video_signal_type, colour description
            if r.u(1) == 1 { _ = r.ue(); _ = r.ue() }                  // chroma_loc_info
            if r.u(1) == 1 { r.skip(65) }                              // timing_info
            let nalHRD = r.u(1) == 1
            if nalHRD { skipHRD(&r) }
            let vclHRD = r.u(1) == 1
            if vclHRD { skipHRD(&r) }
            if nalHRD || vclHRD { r.skip(1) }                          // low_delay_hrd_flag
            r.skip(1)                                                  // pic_struct_present_flag
            guard !r.overrun else { return nil }
            if r.u(1) == 1 { return nal }                              // already has a restriction
            w.copy(r.data, bits: r.position - 1)
        }
        guard !r.overrun else { return nil }

        w.put(1, bits: 1)                            // bitstream_restriction_flag
        w.put(1, bits: 1)                            // motion_vectors_over_pic_boundaries_flag
        w.ue(2); w.ue(1); w.ue(16); w.ue(16)         // spec defaults for the size and MV limits
        w.ue(0)                                      // max_num_reorder_frames
        w.ue(max(1, maxRefFrames))                   // max_dec_frame_buffering
        w.put(1, bits: 1)                            // rbsp_stop_one_bit, then zero padding
        return [nal[0]] + addEmulationPrevention(w.bytes)
    }

    private static func skipHRD(_ r: inout BitReader) {
        let count = r.ue() + 1
        r.skip(8)                                    // bit_rate_scale, cpb_size_scale
        for _ in 0..<count { _ = r.ue(); _ = r.ue(); r.skip(1) }
        r.skip(20)                                   // four 5-bit length fields
    }

    private static func removeEmulationPrevention(_ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [], zeros = 0
        for byte in b {
            if zeros >= 2 && byte == 3 { zeros = 0; continue }
            zeros = byte == 0 ? zeros + 1 : 0
            out.append(byte)
        }
        return out
    }

    private static func addEmulationPrevention(_ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [], zeros = 0
        for byte in b {
            if zeros >= 2 && byte <= 3 { out.append(3); zeros = 0 }
            zeros = byte == 0 ? zeros + 1 : 0
            out.append(byte)
        }
        return out
    }
}

private struct BitReader {
    let data: [UInt8]
    private(set) var position = 0
    var overrun: Bool { position > data.count * 8 }

    init(_ data: [UInt8]) { self.data = data }

    mutating func u(_ n: Int) -> Int {
        var value = 0
        for _ in 0..<n {
            let bit = position < data.count * 8 ? Int(data[position / 8] >> (7 - position % 8) & 1) : 0
            value = value << 1 | bit
            position += 1
        }
        return value
    }

    mutating func skip(_ n: Int) { position += n }

    mutating func ue() -> Int {
        var zeros = 0
        while u(1) == 0 && zeros < 32 { zeros += 1 }
        return (1 << zeros) - 1 + u(zeros)
    }

    mutating func se() -> Int {
        let k = ue()
        return k % 2 == 1 ? (k + 1) / 2 : -(k / 2)
    }
}

private struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var bitCount = 0

    mutating func put(_ value: Int, bits: Int) {
        for i in stride(from: bits - 1, through: 0, by: -1) {
            if bitCount % 8 == 0 { bytes.append(0) }
            if value >> i & 1 == 1 { bytes[bytes.count - 1] |= 0x80 >> UInt8(bitCount % 8) }
            bitCount += 1
        }
    }

    mutating func ue(_ value: Int) {
        let v = value + 1
        let length = Int.bitWidth - v.leadingZeroBitCount
        put(0, bits: length - 1)
        put(v, bits: length)
    }

    mutating func copy(_ source: [UInt8], bits: Int) {
        for i in 0..<bits { put(Int(source[i / 8] >> (7 - i % 8) & 1), bits: 1) }
    }
}
