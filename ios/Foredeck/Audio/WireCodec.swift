import Foundation
import ForedeckCore

/// Converts between the engine's float samples and what goes on the wire.
///
/// The indirection exists so the wire format can change without the audio
/// engine, the packetiser or the jitter buffer knowing. Today that means
/// choosing between mu-law and raw PCM; tomorrow it is where AAC-ELD or Opus
/// arrives.
protocol WireCodec: AnyObject {
    var codecID: CodecID { get }
    func encode(_ samples: [Float]) -> Data
    /// Returns an empty array for a payload this codec cannot make sense of.
    func decode(_ data: Data) -> [Float]
    func reset()
}

/// Default. 128 kbit/s at 16 kHz -- half of raw PCM, and simple enough that
/// `MuLawTests` can verify every one of its 256 output codes.
final class MuLawCodec: WireCodec {
    let codecID: CodecID = .pcmuLaw

    func encode(_ samples: [Float]) -> Data {
        MuLaw.encode(samples: samples)
    }

    func decode(_ data: Data) -> [Float] {
        MuLaw.decodeToFloat(data: data)
    }

    func reset() {}
}

/// Bit-exact, and twice the bandwidth. Useful as a reference when diagnosing
/// whether a quality problem is the codec or the network.
final class PCM16Codec: WireCodec {
    let codecID: CodecID = .pcm16

    func encode(_ samples: [Float]) -> Data {
        var out = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let value = Int16(clamping: Int(clamped * 32_767.0))
            out.append(UInt8(truncatingIfNeeded: value))
            out.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        return out
    }

    func decode(_ data: Data) -> [Float] {
        guard data.count >= 2 else { return [] }
        var out = [Float]()
        out.reserveCapacity(data.count / 2)
        var index = data.startIndex
        while index + 1 < data.endIndex {
            let value = Int16(bitPattern: UInt16(data[index]) | (UInt16(data[index + 1]) << 8))
            out.append(Float(value) / 32_768.0)
            index += 2
        }
        return out
    }

    func reset() {}
}

enum CodecFactory {
    static func make(_ id: CodecID) -> WireCodec? {
        switch id {
        case .pcmuLaw: return MuLawCodec()
        case .pcm16: return PCM16Codec()
        case .aacELD: return nil  // Not implemented; see README.
        }
    }
}
