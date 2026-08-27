import SwiftUI

/// Visual rules for a screen that gets used on a wet, moving foredeck.
///
/// These are constraints rather than decoration. Targets are sized for cold or
/// gloved hands, contrast is set for direct sunlight, and night mode keeps to
/// reds so nobody loses their dark adaptation halfway through an anchoring.
enum Deck {
    /// Comfortably above the 44 pt minimum: this gets pressed by someone who is
    /// not looking at it, on a boat that is moving.
    static let minimumTarget: CGFloat = 64
    static let talkControlSize: CGFloat = 200
    static let corner: CGFloat = 16

    static func background(night: Bool) -> Color {
        night ? Color.black : Color(white: 0.07)
    }

    static func surface(night: Bool) -> Color {
        night ? Color(red: 0.10, green: 0.02, blue: 0.02) : Color(white: 0.15)
    }

    static func primaryText(night: Bool) -> Color {
        night ? Color(red: 1.0, green: 0.42, blue: 0.35) : .white
    }

    static func secondaryText(night: Bool) -> Color {
        night ? Color(red: 0.75, green: 0.30, blue: 0.25) : Color(white: 0.70)
    }

    static func accent(night: Bool) -> Color {
        night ? Color(red: 1.0, green: 0.35, blue: 0.25) : Color(red: 0.20, green: 0.75, blue: 0.55)
    }

    static func warning(night: Bool) -> Color {
        night ? Color(red: 1.0, green: 0.55, blue: 0.30) : Color(red: 0.95, green: 0.65, blue: 0.20)
    }

    static func danger(night: Bool) -> Color {
        night ? Color(red: 1.0, green: 0.30, blue: 0.25) : Color(red: 0.90, green: 0.25, blue: 0.25)
    }

    /// Numbers that get read at a glance from two metres away.
    static func readout(_ size: CGFloat = 48) -> Font {
        .system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
    }
}

struct DeckCard<Content: View>: View {
    let night: Bool
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Deck.surface(night: night), in: RoundedRectangle(cornerRadius: Deck.corner))
    }
}

/// Fills the whole target area, so a press that lands slightly off still counts.
struct DeckButtonStyle: ButtonStyle {
    var night: Bool
    var tint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .semibold, design: .rounded))
            .foregroundStyle(Deck.primaryText(night: night))
            .frame(maxWidth: .infinity, minHeight: Deck.minimumTarget)
            .background(
                (tint ?? Deck.surface(night: night)).opacity(configuration.isPressed ? 0.65 : 1.0),
                in: RoundedRectangle(cornerRadius: Deck.corner)
            )
    }
}
