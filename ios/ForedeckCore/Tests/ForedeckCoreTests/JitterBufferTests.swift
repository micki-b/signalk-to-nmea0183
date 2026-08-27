import XCTest
@testable import ForedeckCore

final class JitterBufferTests: XCTestCase {
    private let sampleRate: Double = 16_000
    private let samplesPerFrame: UInt32 = 320  // 20 ms at 16 kHz

    private func makeBuffer(target: Int = 2, resyncThreshold: Int = 40) -> JitterBuffer {
        var config = JitterBufferConfig()
        config.minDepthFrames = target
        config.initialDepthFrames = target
        config.maxDepthFrames = 6
        config.resyncThresholdFrames = resyncThreshold
        return JitterBuffer(sampleRate: sampleRate, config: config)
    }

    private func packet(_ sequence: UInt16, flags: AudioPacketFlags = []) -> AudioPacket {
        AudioPacket(
            codec: .pcm16,
            flags: flags,
            sequence: sequence,
            timestamp: UInt32(sequence) &* samplesPerFrame,
            payload: Data([UInt8(sequence & 0xFF)])
        )
    }

    private func push(_ buffer: JitterBuffer, _ sequences: [UInt16], startingAt time: Double = 0) {
        for (index, sequence) in sequences.enumerated() {
            buffer.push(packet(sequence), arrivalTime: time + Double(index) * 0.02)
        }
    }

    func testWaitsForTargetDepthBeforePlaying() {
        let buffer = makeBuffer(target: 3)
        buffer.push(packet(0), arrivalTime: 0)
        XCTAssertEqual(buffer.pop(), .silence)
        buffer.push(packet(1), arrivalTime: 0.02)
        XCTAssertEqual(buffer.pop(), .silence)
        buffer.push(packet(2), arrivalTime: 0.04)
        XCTAssertEqual(buffer.pop(), .frame(packet(0)))
    }

    func testPlaysInOrder() {
        let buffer = makeBuffer()
        push(buffer, [0, 1, 2])
        XCTAssertEqual(buffer.pop(), .frame(packet(0)))
        XCTAssertEqual(buffer.pop(), .frame(packet(1)))
        XCTAssertEqual(buffer.pop(), .frame(packet(2)))
    }

    func testReordersOutOfOrderArrivals() {
        let buffer = makeBuffer()
        push(buffer, [0, 2, 1])
        XCTAssertEqual(buffer.pop(), .frame(packet(0)))
        XCTAssertEqual(buffer.pop(), .frame(packet(1)))
        XCTAssertEqual(buffer.pop(), .frame(packet(2)))
    }

    func testDropsDuplicates() {
        let buffer = makeBuffer()
        push(buffer, [0, 1, 1, 1])
        XCTAssertEqual(buffer.stats.duplicates, 2)
        XCTAssertEqual(buffer.pop(), .frame(packet(0)))
        XCTAssertEqual(buffer.pop(), .frame(packet(1)))
    }

    func testDropsPacketsThatArriveTooLateToPlay() {
        let buffer = makeBuffer()
        push(buffer, [0, 1])
        XCTAssertEqual(buffer.pop(), .frame(packet(0)))
        buffer.push(packet(0), arrivalTime: 0.1)
        XCTAssertEqual(buffer.stats.late, 1)
        XCTAssertEqual(buffer.pop(), .frame(packet(1)))
    }

    func testConcealsAHoleWhenNewerFramesAreWaiting() {
        let buffer = makeBuffer()
        push(buffer, [0, 1, 3])
        XCTAssertEqual(buffer.pop(), .frame(packet(0)))
        XCTAssertEqual(buffer.pop(), .frame(packet(1)))
        // Frame 2 never arrived; repeat frame 1 rather than clicking.
        XCTAssertEqual(buffer.pop(), .concealed(packet(1)))
        XCTAssertEqual(buffer.pop(), .frame(packet(3)))
        XCTAssertEqual(buffer.stats.concealed, 1)
    }

    func testUnderrunReturnsSilenceAndDeepensTheBuffer() {
        let buffer = makeBuffer(target: 2)
        let depthBefore = buffer.targetDepth
        push(buffer, [0, 1])
        XCTAssertEqual(buffer.pop(), .frame(packet(0)))
        XCTAssertEqual(buffer.pop(), .frame(packet(1)))
        XCTAssertEqual(buffer.pop(), .silence)
        XCTAssertEqual(buffer.stats.underruns, 1)
        XCTAssertGreaterThan(buffer.targetDepth, depthBefore)
    }

    func testRebuffersAfterUnderrun() {
        let buffer = makeBuffer(target: 2)
        push(buffer, [0, 1])
        _ = buffer.pop()
        _ = buffer.pop()
        XCTAssertEqual(buffer.pop(), .silence)

        // Feed frames until whatever depth the underrun settled on is met.
        var sequence: UInt16 = 2
        var time = 0.2
        while buffer.pendingFrameCount < buffer.targetDepth {
            buffer.push(packet(sequence), arrivalTime: time)
            sequence += 1
            time += 0.02
        }
        XCTAssertEqual(buffer.pop(), .frame(packet(2)))
    }

    func testSurvivesSequenceWraparound() {
        let buffer = makeBuffer()
        push(buffer, [65_534, 65_535, 0, 1])
        XCTAssertEqual(buffer.pop(), .frame(packet(65_534)))
        XCTAssertEqual(buffer.pop(), .frame(packet(65_535)))
        XCTAssertEqual(buffer.pop(), .frame(packet(0)))
        XCTAssertEqual(buffer.pop(), .frame(packet(1)))
        XCTAssertEqual(buffer.stats.concealed, 0)
        XCTAssertEqual(buffer.stats.underruns, 0)
    }

    func testResynchronisesAfterALargeForwardJump() {
        let buffer = makeBuffer(target: 2, resyncThreshold: 40)
        buffer.push(packet(0), arrivalTime: 0)
        // Sender restarted, or we were suspended in someone's pocket.
        buffer.push(packet(500), arrivalTime: 1.0)

        XCTAssertEqual(buffer.stats.resyncs, 1)
        // The stale frame is discarded rather than concealed across.
        XCTAssertEqual(buffer.pendingFrameCount, 1)

        var sequence: UInt16 = 501
        var time = 1.02
        while buffer.pendingFrameCount < buffer.targetDepth {
            buffer.push(packet(sequence), arrivalTime: time)
            sequence += 1
            time += 0.02
        }
        // Playback resumes on live data, not five hundred frames in the past.
        XCTAssertEqual(buffer.pop(), .frame(packet(500)))
        XCTAssertEqual(buffer.stats.concealed, 0)
    }

    func testEndOfSpurtRebuffersInsteadOfConcealingIntoSilence() {
        let buffer = makeBuffer(target: 2)
        buffer.push(packet(0, flags: .endOfSpurt), arrivalTime: 0)
        buffer.push(packet(1), arrivalTime: 0.02)
        XCTAssertEqual(buffer.pop(), .frame(packet(0, flags: .endOfSpurt)))
        // Gate closed: refill before the next spurt rather than concealing.
        XCTAssertEqual(buffer.pop(), .silence)
        XCTAssertEqual(buffer.stats.concealed, 0)
        buffer.push(packet(2), arrivalTime: 0.04)
        XCTAssertEqual(buffer.pop(), .frame(packet(1)))
    }

    func testStopsConcealingAfterTheLimit() {
        var config = JitterBufferConfig()
        config.minDepthFrames = 1
        config.initialDepthFrames = 1
        config.maxConcealedFrames = 3
        config.resyncThresholdFrames = 10_000
        let buffer = JitterBuffer(sampleRate: sampleRate, config: config)

        buffer.push(packet(0), arrivalTime: 0)
        buffer.push(packet(50), arrivalTime: 0.02)
        XCTAssertEqual(buffer.pop(), .frame(packet(0)))
        for _ in 0..<3 { XCTAssertEqual(buffer.pop(), .concealed(packet(0))) }
        XCTAssertEqual(buffer.pop(), .silence)
    }

    func testJitterEstimateGrowsWithErraticArrivals() {
        let buffer = makeBuffer()
        // Frames spaced 20 ms in media time but arriving at wildly uneven times.
        let arrivals: [Double] = [0, 0.02, 0.09, 0.10, 0.19, 0.20]
        for (index, arrival) in arrivals.enumerated() {
            buffer.push(packet(UInt16(index)), arrivalTime: arrival)
        }
        XCTAssertGreaterThan(buffer.jitterEstimate, 0)
    }

    func testResetClearsEverything() {
        let buffer = makeBuffer()
        push(buffer, [0, 1, 2])
        _ = buffer.pop()
        buffer.reset()
        XCTAssertEqual(buffer.pendingFrameCount, 0)
        XCTAssertEqual(buffer.pop(), .silence)
    }
}
