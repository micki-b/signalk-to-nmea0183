import XCTest
@testable import ForedeckCore

final class VoiceActivityDetectorTests: XCTestCase {
    private func rms(dbfs: Double) -> Float {
        Float(pow(10.0, dbfs / 20.0))
    }

    private func feed(_ detector: inout VoiceActivityDetector, dbfs: Double, frames: Int) {
        for _ in 0..<frames { detector.process(frameRMS: rms(dbfs: dbfs)) }
    }

    func testStaysClosedOnSilence() {
        var detector = VoiceActivityDetector()
        feed(&detector, dbfs: -80, frames: 50)
        XCTAssertFalse(detector.isSpeaking)
    }

    func testOpensOnSpeechAfterAttackFrames() {
        var detector = VoiceActivityDetector()
        feed(&detector, dbfs: -80, frames: 20)

        detector.process(frameRMS: rms(dbfs: -14))
        XCTAssertFalse(detector.isSpeaking, "one loud frame should not open the gate")
        detector.process(frameRMS: rms(dbfs: -14))
        XCTAssertTrue(detector.isSpeaking)
    }

    func testSingleTransientDoesNotOpenTheGate() {
        var detector = VoiceActivityDetector()
        feed(&detector, dbfs: -80, frames: 20)
        // A halyard slap: one loud frame, then quiet again.
        detector.process(frameRMS: rms(dbfs: -10))
        feed(&detector, dbfs: -80, frames: 5)
        XCTAssertFalse(detector.isSpeaking)
    }

    func testHangoverHoldsTheGateOpenThroughShortPauses() {
        var detector = VoiceActivityDetector()
        feed(&detector, dbfs: -80, frames: 20)
        feed(&detector, dbfs: -14, frames: 5)
        XCTAssertTrue(detector.isSpeaking)

        // 15 frames is 300 ms, inside the 400 ms hangover: a gap between words,
        // not the end of the sentence.
        feed(&detector, dbfs: -80, frames: 15)
        XCTAssertTrue(detector.isSpeaking)

        feed(&detector, dbfs: -80, frames: 10)
        XCTAssertFalse(detector.isSpeaking)
    }

    func testReportsTheFrameOnWhichItClosed() {
        var detector = VoiceActivityDetector()
        feed(&detector, dbfs: -80, frames: 20)
        feed(&detector, dbfs: -14, frames: 5)

        var closedFrames = 0
        for _ in 0..<40 {
            detector.process(frameRMS: rms(dbfs: -80))
            if detector.didCloseThisFrame { closedFrames += 1 }
        }
        XCTAssertEqual(closedFrames, 1, "end of spurt should be signalled exactly once")
    }

    func testNoiseFloorRisesSlowlyAsTheWindGetsUp() {
        var detector = VoiceActivityDetector()
        feed(&detector, dbfs: -90, frames: 50)
        XCTAssertLessThan(detector.noiseFloorDBFS, -85)

        feed(&detector, dbfs: -60, frames: 400)
        XCTAssertGreaterThan(detector.noiseFloorDBFS, -70)
        XCTAssertFalse(detector.isSpeaking, "steady wind is not speech")
    }

    func testNoiseFloorFallsQuicklyWhenItGoesQuiet() {
        var detector = VoiceActivityDetector()
        feed(&detector, dbfs: -60, frames: 200)
        feed(&detector, dbfs: -90, frames: 40)
        XCTAssertLessThan(detector.noiseFloorDBFS, -85)
    }

    /// In a very quiet cabin the adaptive threshold would sit absurdly low.
    /// The absolute floor is what stops the gate opening on a rustle.
    func testAbsoluteFloorPreventsAHairTrigger() {
        var config = VoiceActivityDetector.Config()
        config.sensitivity = 1.0
        var detector = VoiceActivityDetector(config: config)

        feed(&detector, dbfs: -90, frames: 100)
        XCTAssertGreaterThanOrEqual(detector.thresholdDBFS, -53)

        feed(&detector, dbfs: -70, frames: 10)
        XCTAssertFalse(detector.isSpeaking)
    }

    func testSensitivityWidensAndNarrowsTheMargin() {
        var quiet = VoiceActivityDetector.Config()
        quiet.sensitivity = 1.0
        var loud = VoiceActivityDetector.Config()
        loud.sensitivity = 0.0
        XCTAssertLessThan(
            VoiceActivityDetector(config: quiet).marginDB,
            VoiceActivityDetector(config: loud).marginDB
        )
    }

    func testResetForgetsTheEnvironment() {
        var detector = VoiceActivityDetector()
        feed(&detector, dbfs: -14, frames: 10)
        XCTAssertTrue(detector.isSpeaking)
        detector.reset()
        XCTAssertFalse(detector.isSpeaking)
    }

    func testRMSHelpers() {
        XCTAssertEqual(VoiceActivityDetector.rms(of: [Float](repeating: 0.5, count: 64)), 0.5, accuracy: 1e-6)
        XCTAssertEqual(VoiceActivityDetector.rms(of: [Int16](repeating: 16_384, count: 64)), 0.5, accuracy: 1e-3)
        XCTAssertEqual(VoiceActivityDetector.rms(of: [Float]()), 0)
    }
}
