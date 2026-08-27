import XCTest
@testable import ForedeckCore

final class AudioPacketTests: XCTestCase {
    func testRoundTripPreservesEveryField() {
        let packet = AudioPacket(
            codec: .pcm16,
            flags: [.speaking, .endOfSpurt],
            sequence: 40_000,
            timestamp: 3_000_000_000,
            payload: Data([1, 2, 3, 4, 5])
        )
        let decoded = AudioPacket(decoding: packet.encoded())
        XCTAssertEqual(decoded, packet)
    }

    func testHeaderIsExactlyEightBytes() {
        let packet = AudioPacket(codec: .pcm16, sequence: 0, timestamp: 0, payload: Data([9]))
        XCTAssertEqual(packet.encoded().count, AudioPacket.headerSize + 1)
    }

    func testEmptyPayloadIsLegal() {
        let packet = AudioPacket(codec: .aacELD, sequence: 7, timestamp: 7, payload: Data())
        let decoded = AudioPacket(decoding: packet.encoded())
        XCTAssertEqual(decoded?.payload.count, 0)
        XCTAssertEqual(decoded?.sequence, 7)
    }

    func testRejectsTruncatedData() {
        XCTAssertNil(AudioPacket(decoding: Data([0x10, 0, 0, 0])))
        XCTAssertNil(AudioPacket(decoding: Data()))
    }

    func testRejectsUnknownVersion() {
        var encoded = AudioPacket(codec: .pcm16, sequence: 1, timestamp: 1, payload: Data([0])).encoded()
        encoded[0] = (9 << 4) | 0
        XCTAssertNil(AudioPacket(decoding: encoded))
    }

    func testRejectsUnknownCodec() {
        var encoded = AudioPacket(codec: .pcm16, sequence: 1, timestamp: 1, payload: Data([0])).encoded()
        encoded[0] = (AudioPacket.version << 4) | 0x0E
        XCTAssertNil(AudioPacket(decoding: encoded))
    }

    /// Multipeer hands us a Data slice; indexing from zero rather than from
    /// startIndex would silently read the wrong bytes.
    func testDecodesFromANonZeroBasedSlice() {
        let packet = AudioPacket(codec: .pcm16, sequence: 513, timestamp: 99, payload: Data([7, 7, 7]))
        let padded = Data([0xAA, 0xBB]) + packet.encoded()
        let slice = padded.dropFirst(2)
        XCTAssertEqual(AudioPacket(decoding: slice), packet)
    }

    func testSerialNumberComparisonHandlesWraparound() {
        XCTAssertTrue(SerialNumber16.isNewer(1, than: 65_535))
        XCTAssertFalse(SerialNumber16.isNewer(65_535, than: 1))
        XCTAssertTrue(SerialNumber16.isNewer(100, than: 99))
        XCTAssertFalse(SerialNumber16.isNewer(100, than: 100))
    }

    func testSerialDistanceIsSignedAcrossTheWrap() {
        XCTAssertEqual(SerialNumber16.distance(from: 65_535, to: 2), 3)
        XCTAssertEqual(SerialNumber16.distance(from: 2, to: 65_535), -3)
        XCTAssertEqual(SerialNumber16.distance(from: 10, to: 20), 10)
    }
}
