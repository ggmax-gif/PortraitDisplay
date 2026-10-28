import CoreMedia
@testable import PortraitHost
import XCTest

final class CodecTests: XCTestCase {
    /// The hvcC VideoToolbox's hardware HEVC encoder produced at 2048×2668 (Main profile, level 5.1).
    private let hvcC = hex("""
        010160000000b0000000000099f000fcfdf8f800000b03a00001001840010c01ffff016000000300b0000003000003\
        0099170240a100010025420101016000000300b00000030000030099a0010020029c7de205ee45914bff2e7f13fa20\
        a2000100074401c072f05324
        """)

    /// The avcC VideoToolbox's hardware H.264 encoder produced at 2048×2668 (High, level 5.1), before
    /// H264NoReorder: its SPS has no VUI, so decoders may assume frames are reordered.
    private let avcC = hex("01640033ffe1000c27640033ac5680200053fed001000428ee3cb0fdf8f800")

    func testHEVCCodecStringFollowsISO14496Part15() {
        XCTAssertEqual(VideoEncoder.hevcCodecString(Data(hvcC)), "hvc1.1.6.L153.B0")
    }

    func testPatchedSPSSaysNoFramesAreReordered() throws {
        XCTAssertNil(try reorderFrames(sps(of: avcC)), "the fixture should start without a bitstream restriction")
        let patched = try XCTUnwrap(H264NoReorder.patch(avcC: Data(avcC)))
        XCTAssertEqual(try reorderFrames(sps(of: [UInt8](patched))), 0)
    }

    func testPatchedSPSStillDescribesTheSamePicture() throws {
        let patched = [UInt8](try XCTUnwrap(H264NoReorder.patch(avcC: Data(avcC))))
        let sps = try sps(of: patched), pps = [UInt8](patched.suffix(from: 6 + 2 + sps.count + 3).prefix(4))
        var format: CMFormatDescription?
        let status = sps.withUnsafeBufferPointer { s in
            pps.withUnsafeBufferPointer { p in
                let sets = [s.baseAddress!, p.baseAddress!], sizes = [s.count, p.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2,
                    parameterSetPointers: sets, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        XCTAssertEqual(status, noErr)
        let dimensions = try XCTUnwrap(format).dimensions
        XCTAssertEqual([dimensions.width, dimensions.height], [2048, 2668])
    }

    func testPatchingTwiceChangesNothingMore() throws {
        let once = try XCTUnwrap(H264NoReorder.patch(avcC: Data(avcC)))
        XCTAssertEqual(H264NoReorder.patch(avcC: once), once)
    }

    // MARK: An independent SPS reader (ITU-T H.264 7.3.2.1.1 and E.1.1), only as far as the test needs

    private func sps(of avcC: [UInt8]) throws -> [UInt8] {
        XCTAssertEqual(avcC[5] & 0x1F, 1, "one SPS")
        let length = Int(avcC[6]) << 8 | Int(avcC[7])
        return Array(avcC[8..<(8 + length)])
    }

    /// max_num_reorder_frames from the SPS's VUI, or nil when there's no bitstream restriction.
    private func reorderFrames(_ nal: [UInt8]) throws -> Int? {
        var r = Bits(nal.dropFirst())
        let profile = r.u(8)
        r.skip(16)                                                // constraint flags, level_idc
        _ = r.ue()                                                // seq_parameter_set_id
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            XCTAssertNotEqual(r.ue(), 3, "chroma_format_idc 4:4:4 isn't in the fixture")
            _ = r.ue(); _ = r.ue(); r.skip(1)                     // bit depths, transform bypass
            XCTAssertEqual(r.u(1), 0, "no scaling matrix in the fixture")
        }
        _ = r.ue()                                                // log2_max_frame_num_minus4
        let pocType = r.ue()
        if pocType == 0 { _ = r.ue() }
        XCTAssertNotEqual(pocType, 1, "pic_order_cnt_type 1 isn't in the fixture")
        _ = r.ue(); r.skip(1); _ = r.ue(); _ = r.ue()             // ref frames, gaps, width, height
        if r.u(1) == 0 { r.skip(1) }                              // frame_mbs_only, mb_adaptive
        r.skip(1)                                                 // direct_8x8_inference
        if r.u(1) == 1 { for _ in 0..<4 { _ = r.ue() } }          // frame cropping
        guard r.u(1) == 1 else { return nil }                     // vui_parameters_present_flag
        if r.u(1) == 1 { if r.u(8) == 255 { r.skip(32) } }        // aspect ratio
        if r.u(1) == 1 { r.skip(1) }                              // overscan
        if r.u(1) == 1 { r.skip(4); if r.u(1) == 1 { r.skip(24) } }   // video signal, colour
        if r.u(1) == 1 { _ = r.ue(); _ = r.ue() }                 // chroma location
        if r.u(1) == 1 { r.skip(65) }                             // timing
        XCTAssertEqual(r.u(1), 0, "no NAL HRD in the fixture")
        XCTAssertEqual(r.u(1), 0, "no VCL HRD in the fixture")
        r.skip(1)                                                 // pic_struct_present
        guard r.u(1) == 1 else { return nil }                     // bitstream_restriction_flag
        r.skip(1)                                                 // motion_vectors_over_pic_boundaries
        for _ in 0..<4 { _ = r.ue() }                             // max bytes / bits, MV lengths
        return r.ue()
    }

    private struct Bits {
        let bytes: [UInt8]
        var position = 0
        init<S: Sequence>(_ nal: S) where S.Element == UInt8 {
            var out: [UInt8] = [], zeros = 0                       // drop emulation-prevention bytes
            for byte in nal {
                if zeros >= 2 && byte == 3 { zeros = 0; continue }
                zeros = byte == 0 ? zeros + 1 : 0
                out.append(byte)
            }
            bytes = out
        }
        mutating func u(_ n: Int) -> Int {
            var v = 0
            for _ in 0..<n {
                v = v << 1 | (position < bytes.count * 8 ? Int(bytes[position / 8] >> (7 - position % 8) & 1) : 0)
                position += 1
            }
            return v
        }
        mutating func skip(_ n: Int) { position += n }
        mutating func ue() -> Int {
            var zeros = 0
            while u(1) == 0 && zeros < 32 { zeros += 1 }
            return (1 << zeros) - 1 + u(zeros)
        }
    }
}

private func hex(_ s: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var index = s.startIndex
    while index < s.endIndex {
        let next = s.index(index, offsetBy: 2)
        bytes.append(UInt8(s[index..<next], radix: 16)!)
        index = next
    }
    return bytes
}
