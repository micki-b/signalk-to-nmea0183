import SwiftUI
import ForedeckCore
#if canImport(UIKit)
import UIKit
#endif

/// The one control that has to work without being looked at.
///
/// In open mic it is an indicator, not a button: it shows that the gate is open
/// and how loud you are, because the commonest failure on the water is talking
/// into a phone that is not transmitting and not knowing it. In push-to-talk it
/// is a press-and-hold target big enough to hit blind, with haptics on both
/// edges so the confirmation is felt rather than seen.
struct TalkControl: View {
    let mode: TalkMode
    let isSpeaking: Bool
    let inputLevelDBFS: Double
    let night: Bool
    let onPushToTalk: (Bool) -> Void

    @State private var isHeld = false

    private var level: Double {
        // -60 dBFS to 0 mapped onto the ring.
        min(max((inputLevelDBFS + 60) / 60, 0), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Deck.surface(night: night))

            Circle()
                .stroke(Deck.secondaryText(night: night).opacity(0.3), lineWidth: 6)
                .padding(10)

            Circle()
                .trim(from: 0, to: level)
                .stroke(
                    isSpeaking ? Deck.accent(night: night) : Deck.secondaryText(night: night),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .padding(10)
                .animation(.linear(duration: 0.1), value: level)

            if isSpeaking {
                Circle()
                    .stroke(Deck.accent(night: night), lineWidth: 3)
                    .padding(2)
                    .transition(.opacity)
            }

            VStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: 44, weight: .medium))
                Text(caption)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(isSpeaking ? Deck.accent(night: night) : Deck.primaryText(night: night))
        }
        .frame(width: Deck.talkControlSize, height: Deck.talkControlSize)
        .contentShape(Circle())
        .gesture(pushToTalkGesture)
        .animation(.easeOut(duration: 0.15), value: isSpeaking)
        .accessibilityLabel(mode == .pushToTalk ? "Push to talk" : "Open microphone")
        .accessibilityValue(isSpeaking ? "Transmitting" : "Silent")
    }

    private var iconName: String {
        switch mode {
        case .openMic: return isSpeaking ? "waveform" : "mic"
        case .pushToTalk: return isHeld ? "mic.fill" : "mic.slash"
        }
    }

    private var caption: String {
        switch mode {
        case .openMic: return isSpeaking ? "On air" : "Open mic"
        case .pushToTalk: return isHeld ? "On air" : "Hold to talk"
        }
    }

    private var pushToTalkGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard mode == .pushToTalk, !isHeld else { return }
                isHeld = true
                onPushToTalk(true)
                #if canImport(UIKit)
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                #endif
            }
            .onEnded { _ in
                guard mode == .pushToTalk, isHeld else { return }
                isHeld = false
                onPushToTalk(false)
                #if canImport(UIKit)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                #endif
            }
    }
}
