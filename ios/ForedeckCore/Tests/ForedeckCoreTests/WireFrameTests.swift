import XCTest
@testable import ForedeckCore

final class WireFrameTests: XCTestCase {
    func testAudioAndControlAreDistinguishable() throws {
        let packet = AudioPacket(codec: .pcmuLaw, sequence: 12, timestamp: 3_840, payload: Data([1, 2, 3]))
        let envelope = ControlEnvelope(
            sender: CrewIdentity(deviceID: "AAA", displayName: "Skipper", role: .helm),
            stamp: LamportStamp(counter: 1, deviceID: "AAA"),
            message: .speaking(true)
        )

        guard case .audio(let audio)? = WireFrame.classify(packet.encoded()) else {
            return XCTFail("audio frame misclassified")
        }
        XCTAssertEqual(AudioPacket(decoding: audio), packet)

        let framed = WireFrame.framedControl(try envelope.encoded())
        guard case .control(let control)? = WireFrame.classify(framed) else {
            return XCTFail("control frame misclassified")
        }
        XCTAssertEqual(try ControlEnvelope(decoding: control), envelope)
    }

    func testEveryCodecStillSetsANonZeroFirstByte() {
        // The tagging scheme relies on audio never colliding with the control
        // tag. If a future codec id broke that, this catches it.
        for codec in CodecID.allCases {
            let encoded = AudioPacket(codec: codec, sequence: 0, timestamp: 0, payload: Data()).encoded()
            XCTAssertNotEqual(encoded.first, WireFrame.controlTag)
        }
    }

    func testEmptyDataIsRejected() {
        XCTAssertNil(WireFrame.classify(Data()))
    }

    func testControlPayloadSurvivesASlicedBuffer() throws {
        let payload = Data("hello".utf8)
        let framed = WireFrame.framedControl(payload)
        let padded = Data([0xFF, 0xFF]) + framed
        guard case .control(let recovered)? = WireFrame.classify(padded.dropFirst(2)) else {
            return XCTFail("expected control frame")
        }
        XCTAssertEqual(recovered, payload)
    }
}
