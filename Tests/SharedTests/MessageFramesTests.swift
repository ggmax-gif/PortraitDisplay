import Shared
import XCTest

final class MessageFramesTests: XCTestCase {
    func testRoundTripKeepsPayloadAndKind() throws {
        var buffer = MessageFrames.frame(Data("ack".utf8), isText: true) + MessageFrames.frame(Data([1, 2, 3]), isText: false)
        let messages = try XCTUnwrap(MessageFrames.take(from: &buffer, maxLength: 1024))
        XCTAssertEqual(messages.map(\.payload), [Data("ack".utf8), Data([1, 2, 3])])
        XCTAssertEqual(messages.map(\.isText), [true, false])
        XCTAssertTrue(buffer.isEmpty)
    }

    func testHeaderIsBigEndianLengthThenKind() {
        XCTAssertEqual([UInt8](MessageFrames.frame(Data([0xAB]), isText: false)), [0, 0, 0, 2, 1, 0xAB])
    }

    /// Streams arrive in arbitrary chunks: a message split anywhere must come out whole, once.
    func testMessageSplitAcrossChunksIsDeliveredOnceComplete() throws {
        let framed = MessageFrames.frame(Data(repeating: 7, count: 1000), isText: false)
        for split in [1, 4, 5, 6, 500, framed.count - 1] {
            var buffer = Data(framed.prefix(split))
            XCTAssertEqual(try XCTUnwrap(MessageFrames.take(from: &buffer, maxLength: 4096)).count, 0, "split at \(split)")
            buffer.append(framed.dropFirst(split))
            let messages = try XCTUnwrap(MessageFrames.take(from: &buffer, maxLength: 4096))
            XCTAssertEqual(messages.count, 1, "split at \(split)")
            XCTAssertEqual(messages.first?.payload.count, 1000)
        }
    }

    /// A buffer whose start has been consumed has a non-zero startIndex; indices must stay relative.
    func testWorksOnASliceWithANonZeroStartIndex() throws {
        let both = MessageFrames.frame(Data("one".utf8), isText: true) + MessageFrames.frame(Data("two".utf8), isText: true)
        var buffer = both.dropFirst(0)
        _ = try XCTUnwrap(MessageFrames.take(from: &buffer, maxLength: 64))
        XCTAssertTrue(buffer.isEmpty)
        var shifted = Data([9, 9]) + both
        shifted.removeFirst(2)
        XCTAssertEqual(try XCTUnwrap(MessageFrames.take(from: &shifted, maxLength: 64)).map(\.payload), [Data("one".utf8), Data("two".utf8)])
    }

    func testOversizeOrEmptyLengthMeansABrokenStream() {
        var tooBig = MessageFrames.frame(Data(count: 100), isText: false)
        XCTAssertNil(MessageFrames.take(from: &tooBig, maxLength: 50))
        var zero = Data([0, 0, 0, 0, 0])
        XCTAssertNil(MessageFrames.take(from: &zero, maxLength: 50))
    }
}
