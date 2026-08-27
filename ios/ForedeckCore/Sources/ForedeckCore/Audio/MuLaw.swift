import Foundation

/// G.711 mu-law companding.
///
/// Chosen as the default wire format for a specific reason: it halves the
/// bandwidth of raw 16-bit PCM for a quality cost that is inaudible over an
/// engine, and -- unlike a real perceptual codec -- it is fifteen lines of
/// integer arithmetic that can be tested exhaustively rather than trusted.
/// At 16 kHz it costs 128 kbit/s per talker, which a mesh of four phones
/// carries without noticing.
///
/// The upgrade path is AAC-ELD or Opus behind the same `CodecID`; the packet
/// header already carries the codec so a mixed-version crew degrades to
/// dropping frames it cannot decode rather than playing noise.
public enum MuLaw {
    private static let bias: Int32 = 0x84
    private static let clip: Int32 = 32_635

    public static func encode(_ sample: Int16) -> UInt8 {
        var value = Int32(sample)
        var sign: Int32 = 0
        if value < 0 {
            value = -value
            sign = 0x80
        }
        if value > clip { value = clip }
        value += bias

        // Find the exponent: the position of the most significant set bit,
        // which after the bias is always at bit 7 or above.
        var exponent: Int32 = 7
        var mask: Int32 = 0x4000
        while exponent > 0 && (value & mask) == 0 {
            exponent -= 1
            mask >>= 1
        }
        let mantissa = (value >> (exponent + 3)) & 0x0F
        return UInt8(truncatingIfNeeded: ~(sign | (exponent << 4) | mantissa))
    }

    public static func decode(_ byte: UInt8) -> Int16 {
        let inverted = Int32(~byte)
        let sign = inverted & 0x80
        let exponent = (inverted >> 4) & 0x07
        let mantissa = inverted & 0x0F

        var value = ((mantissa << 3) + bias) << exponent
        value -= bias
        return Int16(clamping: sign != 0 ? -value : value)
    }

    // MARK: - Buffer helpers

    public static func encode(samples: [Int16]) -> Data {
        var out = Data(capacity: samples.count)
        for sample in samples { out.append(encode(sample)) }
        return out
    }

    public static func decode(data: Data) -> [Int16] {
        var out = [Int16]()
        out.reserveCapacity(data.count)
        for byte in data { out.append(decode(byte)) }
        return out
    }

    /// Float in [-1, 1] is what AVAudioEngine deals in; the conversion is
    /// folded in here so callers never hand-roll the scaling and clipping.
    public static func encode(samples: [Float]) -> Data {
        var out = Data(capacity: samples.count)
        for sample in samples {
            let scaled = max(-1.0, min(1.0, sample)) * 32_767.0
            out.append(encode(Int16(scaled.rounded())))
        }
        return out
    }

    public static func decodeToFloat(data: Data) -> [Float] {
        var out = [Float]()
        out.reserveCapacity(data.count)
        for byte in data { out.append(Float(decode(byte)) / 32_768.0) }
        return out
    }
}
