import XCTest
@testable import ForedeckCore

final class MuLawTests: XCTestCase {
    func testSilenceRoundTripsExactly() {
        XCTAssertEqual(MuLaw.decode(MuLaw.encode(0)), 0)
    }

    /// G.711 mu-law has two codes for zero -- 0x7F is "negative zero" -- so
    /// that one code canonicalises to 0xFF. Every other code must be a fixed
    /// point, otherwise audio would drift a little on each decode/re-encode.
    func testNegativeZeroIsTheOnlyNonCanonicalCode() {
        XCTAssertEqual(MuLaw.decode(0x7F), 0)
        XCTAssertEqual(MuLaw.decode(0xFF), 0)
        XCTAssertEqual(MuLaw.encode(0), 0xFF)

        for byte in UInt8.min...UInt8.max where byte != 0x7F {
            let sample = MuLaw.decode(byte)
            XCTAssertEqual(MuLaw.encode(sample), byte, "byte \(byte) is not a fixed point")
        }
    }

    func testQuantisationErrorStaysWithinTheCompandingCurve() {
        // mu-law trades absolute precision for dynamic range: error grows with
        // amplitude, but stays proportionally small everywhere.
        for sample in stride(from: -32_000, through: 32_000, by: 37) {
            let original = Int16(sample)
            let recovered = MuLaw.decode(MuLaw.encode(original))
            let error = abs(Int32(recovered) - Int32(original))
            let tolerance = max(8, Int32(Double(abs(Int32(original))) * 0.08))
            XCTAssertLessThanOrEqual(error, tolerance, "sample \(original) -> \(recovered)")
        }
    }

    func testSignIsPreserved() {
        for sample in stride(from: -32_000, through: 32_000, by: 101) {
            let original = Int16(sample)
            let recovered = MuLaw.decode(MuLaw.encode(original))
            if original > 100 { XCTAssertGreaterThan(recovered, 0) }
            if original < -100 { XCTAssertLessThan(recovered, 0) }
        }
    }

    func testExtremesDoNotWrapAround() {
        XCTAssertGreaterThan(MuLaw.decode(MuLaw.encode(Int16.max)), 30_000)
        XCTAssertLessThan(MuLaw.decode(MuLaw.encode(Int16.min)), -30_000)
    }

    func testBufferRoundTripPreservesLength() {
        let samples: [Int16] = (0..<320).map { Int16(truncatingIfNeeded: $0 * 91) }
        let encoded = MuLaw.encode(samples: samples)
        XCTAssertEqual(encoded.count, 320, "mu-law must be exactly one byte per sample")
        XCTAssertEqual(MuLaw.decode(data: encoded).count, 320)
    }

    func testFloatRoundTripStaysInRange() {
        let samples: [Float] = (0..<320).map { sin(Float($0) * 0.05) * 0.8 }
        let recovered = MuLaw.decodeToFloat(data: MuLaw.encode(samples: samples))
        XCTAssertEqual(recovered.count, samples.count)
        for (original, value) in zip(samples, recovered) {
            XCTAssertEqual(value, original, accuracy: 0.05)
        }
    }

    func testFloatEncodingClipsRatherThanWrapping() {
        let recovered = MuLaw.decodeToFloat(data: MuLaw.encode(samples: [2.0, -2.0]))
        XCTAssertGreaterThan(recovered[0], 0.9)
        XCTAssertLessThan(recovered[1], -0.9)
    }
}
