import Foundation

/// Identifies how the payload of an `AudioPacket` is encoded.
///
/// The value travels in the low nibble of the packet's first byte, so at most
/// sixteen codecs can ever exist. That is plenty, and keeping it in the header
/// means a peer running a newer build can drop frames it cannot decode instead
/// of playing noise.
public enum CodecID: UInt8, Sendable, CaseIterable, Codable {
    /// 16-bit signed little-endian PCM. Bulky but bit-exact and dependency free.
    case pcm16 = 0
    /// MPEG-4 AAC Enhanced Low Delay. Reserved: see README for why this is
    /// the documented upgrade rather than the shipped default.
    case aacELD = 1
    /// G.711 mu-law. Half the bandwidth of PCM for arithmetic simple enough to
    /// verify exhaustively. This is the default.
    case pcmuLaw = 2
}

public struct AudioPacketFlags: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// The sender's voice-activity detector considers this frame speech.
    public static let speaking = AudioPacketFlags(rawValue: 1 << 0)
    /// Last frame of a talk spurt. Lets the receiver release its jitter buffer
    /// early rather than concealing its way to silence.
    public static let endOfSpurt = AudioPacketFlags(rawValue: 1 << 1)
    /// Sender was holding push-to-talk rather than running open mic.
    public static let pushToTalk = AudioPacketFlags(rawValue: 1 << 2)
}

/// One frame of encoded audio on the wire.
///
/// Layout (8-byte header, big-endian, then payload):
///
///     0        version (high nibble) | codec id (low nibble)
///     1        flags
///     2..3     sequence number, wraps
///     4..7     media timestamp in samples, wraps
///     8..      encoded frame
///
/// The header is deliberately tiny: at 50 packets per second per talker the
/// overhead matters, and everything a receiver needs in order to reorder,
/// conceal, and mix is in these eight bytes.
public struct AudioPacket: Equatable, Sendable {
    public static let version: UInt8 = 1
    public static let headerSize = 8

    public var codec: CodecID
    public var flags: AudioPacketFlags
    public var sequence: UInt16
    /// Sample-count timestamp of the first sample in the frame.
    public var timestamp: UInt32
    public var payload: Data

    public init(
        codec: CodecID,
        flags: AudioPacketFlags = [],
        sequence: UInt16,
        timestamp: UInt32,
        payload: Data
    ) {
        self.codec = codec
        self.flags = flags
        self.sequence = sequence
        self.timestamp = timestamp
        self.payload = payload
    }

    public var isSpeaking: Bool { flags.contains(.speaking) }

    public func encoded() -> Data {
        var out = Data(capacity: Self.headerSize + payload.count)
        out.append((Self.version << 4) | (codec.rawValue & 0x0F))
        out.append(flags.rawValue)
        out.append(UInt8(truncatingIfNeeded: sequence >> 8))
        out.append(UInt8(truncatingIfNeeded: sequence))
        out.append(UInt8(truncatingIfNeeded: timestamp >> 24))
        out.append(UInt8(truncatingIfNeeded: timestamp >> 16))
        out.append(UInt8(truncatingIfNeeded: timestamp >> 8))
        out.append(UInt8(truncatingIfNeeded: timestamp))
        out.append(payload)
        return out
    }

    /// Returns nil for anything that is not a well-formed packet of a version
    /// and codec we understand. Callers drop those silently; on a shared
    /// network we will occasionally be handed something that is not ours.
    public init?(decoding data: Data) {
        guard data.count >= Self.headerSize else { return nil }
        let base = data.startIndex
        guard (data[base] >> 4) == Self.version else { return nil }
        guard let codec = CodecID(rawValue: data[base] & 0x0F) else { return nil }

        self.codec = codec
        self.flags = AudioPacketFlags(rawValue: data[base + 1])
        self.sequence = (UInt16(data[base + 2]) << 8) | UInt16(data[base + 3])

        var ts = UInt32(data[base + 4]) << 24
        ts |= UInt32(data[base + 5]) << 16
        ts |= UInt32(data[base + 6]) << 8
        ts |= UInt32(data[base + 7])
        self.timestamp = ts

        // subdata re-bases the returned Data to a zero start index, which
        // matters because decoders index payloads from zero.
        self.payload = data.subdata(in: (base + Self.headerSize)..<data.endIndex)
    }
}

/// RFC 1982 style comparison for the wrapping 16-bit sequence space.
///
/// Sequence numbers wrap every 65536 frames, which at 20 ms per frame is about
/// 22 minutes -- well inside a single anchoring. Naive `<` comparison would
/// stall the jitter buffer for the rest of the session at that point.
public enum SerialNumber16 {
    public static func isNewer(_ a: UInt16, than b: UInt16) -> Bool {
        a != b && (a &- b) < 0x8000
    }

    /// Signed distance from `a` to `b`; positive when `b` is ahead.
    public static func distance(from a: UInt16, to b: UInt16) -> Int {
        let delta = b &- a
        return delta < 0x8000 ? Int(delta) : Int(delta) - 0x1_0000
    }
}
