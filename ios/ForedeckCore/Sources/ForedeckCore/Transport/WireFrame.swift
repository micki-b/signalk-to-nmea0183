import Foundation

/// Audio and control share one Multipeer session but travel in different
/// delivery modes, and the receive callback does not tell us which mode a
/// datagram arrived on. So the first byte has to say.
///
/// Audio frames are self-identifying already -- their first byte carries the
/// protocol version in the high nibble, which is never zero -- so control
/// frames take the reserved 0x00 tag and audio goes on the wire untouched.
public enum WireFrame: Equatable, Sendable {
    case audio(Data)
    case control(Data)

    public static let controlTag: UInt8 = 0x00

    public static func framedControl(_ payload: Data) -> Data {
        var out = Data(capacity: payload.count + 1)
        out.append(controlTag)
        out.append(payload)
        return out
    }

    public static func classify(_ data: Data) -> WireFrame? {
        guard let first = data.first else { return nil }
        if first == controlTag {
            return .control(data.subdata(in: (data.startIndex + 1)..<data.endIndex))
        }
        return .audio(data)
    }
}
