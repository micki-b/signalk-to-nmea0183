import SwiftUI
import ForedeckCore

struct SessionView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var settings: SettingsStore

    private var night: Bool { settings.nightMode }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                statusHeader

                TalkControl(
                    mode: settings.talkMode,
                    isSpeaking: model.localSpeaking,
                    inputLevelDBFS: model.inputLevelDBFS,
                    night: night,
                    onPushToTalk: { model.setPushToTalk(held: $0) }
                )
                .padding(.vertical, 8)

                talkModePicker
                crewRoster
            }
            .padding(20)
        }
        .background(Deck.background(night: night).ignoresSafeArea())
    }

    private var statusHeader: some View {
        DeckCard(night: night) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.boatName)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(Deck.primaryText(night: night))
                    Text(statusText)
                        .font(.system(size: 15))
                        .foregroundStyle(Deck.secondaryText(night: night))
                }
                Spacer()
                Circle()
                    .fill(statusColor)
                    .frame(width: 14, height: 14)
            }
        }
    }

    private var statusText: String {
        switch model.transportState {
        case .idle: return "Not connected"
        case .searching: return "Looking for crew…"
        case .connected(let count): return count == 1 ? "1 crew member" : "\(count) crew members"
        case .failed(let message): return message
        }
    }

    private var statusColor: Color {
        switch model.transportState {
        case .connected: return Deck.accent(night: night)
        case .searching: return Deck.warning(night: night)
        case .failed: return Deck.danger(night: night)
        case .idle: return Deck.secondaryText(night: night)
        }
    }

    private var talkModePicker: some View {
        VStack(spacing: 8) {
            Picker("Talk mode", selection: $settings.talkMode) {
                ForEach(TalkMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(settings.talkMode.explanation)
                .font(.system(size: 14))
                .foregroundStyle(Deck.secondaryText(night: night))
        }
    }

    @ViewBuilder
    private var crewRoster: some View {
        if model.crew.isEmpty {
            DeckCard(night: night) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Nobody else yet")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(Deck.primaryText(night: night))
                    Text("Other crew need Foredeck open and paired to \(model.boatName). They do not need to be on the same WiFi.")
                        .font(.system(size: 15))
                        .foregroundStyle(Deck.secondaryText(night: night))
                }
            }
        } else {
            VStack(spacing: 12) {
                ForEach(model.crew) { member in
                    CrewTile(member: member, night: night)
                        .environmentObject(model)
                }
            }
        }
    }
}

private struct CrewTile: View {
    @EnvironmentObject private var model: AppModel
    let member: CrewMember
    let night: Bool

    var body: some View {
        DeckCard(night: night) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .stroke(
                                member.isSpeaking ? Deck.accent(night: night) : Deck.secondaryText(night: night).opacity(0.4),
                                lineWidth: member.isSpeaking ? 3 : 1.5
                            )
                            .frame(width: 44, height: 44)
                        Text(initials)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(Deck.primaryText(night: night))
                    }
                    .animation(.easeOut(duration: 0.15), value: member.isSpeaking)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.displayName)
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .foregroundStyle(Deck.primaryText(night: night))
                        Text(member.identity.role.label)
                            .font(.system(size: 14))
                            .foregroundStyle(Deck.secondaryText(night: night))
                    }

                    Spacer()

                    if let quality = member.quality, !quality.isHealthy {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .foregroundStyle(Deck.warning(night: night))
                            .accessibilityLabel("Poor link")
                    }

                    Button {
                        model.setMuted(!member.isMuted, for: member)
                    } label: {
                        Image(systemName: member.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 20))
                            .frame(width: Deck.minimumTarget, height: Deck.minimumTarget)
                            .foregroundStyle(member.isMuted ? Deck.danger(night: night) : Deck.primaryText(night: night))
                    }
                    .accessibilityLabel(member.isMuted ? "Unmute \(member.displayName)" : "Mute \(member.displayName)")
                }

                if !member.isMuted {
                    HStack(spacing: 12) {
                        Image(systemName: "speaker.fill")
                            .foregroundStyle(Deck.secondaryText(night: night))
                        Slider(
                            value: Binding(
                                get: { Double(member.volume) },
                                set: { model.setVolume(Float($0), for: member) }
                            ),
                            in: 0...1
                        )
                        .tint(Deck.accent(night: night))
                    }
                }
            }
        }
    }

    private var initials: String {
        let parts = member.displayName.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}
