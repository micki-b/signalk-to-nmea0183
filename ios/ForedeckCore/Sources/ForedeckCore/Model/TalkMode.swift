import Foundation

/// "Full duplex" turns out to mean two different things on a boat.
///
/// Open mic is the point of the app: hands on the lines, nobody pressing
/// anything. But it is gated by voice activity, because a phone clipped to the
/// pushpit in twenty knots otherwise fills everyone's ears with wind for the
/// entire manoeuvre. Push-to-talk stays available for when conditions beat the
/// gate, or when someone simply wants their end shut.
public enum TalkMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case openMic
    case pushToTalk

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .openMic: return "Open mic"
        case .pushToTalk: return "Push to talk"
        }
    }

    public var explanation: String {
        switch self {
        case .openMic: return "Hands free. Transmits when you speak."
        case .pushToTalk: return "Hold the button to talk."
        }
    }
}
