import SwiftUI
import ForedeckCore

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var settings: SettingsStore
    @ObservedObject var boatStore: BoatStore

    @State private var confirmUnpair = false

    var body: some View {
        Form {
            Section("You") {
                TextField("Name", text: $settings.displayName)
                Picker("Station", selection: $settings.role) {
                    ForEach(CrewRole.allCases) { role in
                        Text(role.label).tag(role)
                    }
                }
            }

            Section {
                Picker("Talk mode", selection: $settings.talkMode) {
                    ForEach(TalkMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                VStack(alignment: .leading) {
                    Text("Mic sensitivity")
                    Slider(value: $settings.vadSensitivity, in: 0...1)
                    Text("Lower it when the wind is up and the mic keeps opening on its own; raise it if quiet speech is being cut off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Voice")
            } footer: {
                Text("A headset or AirPods will beat a phone at arm's length in any real wind. Nothing in software fixes a microphone in a gale.")
            }

            Section("Audio quality") {
                Picker("Codec", selection: $settings.codec) {
                    Text("mu-law (recommended)").tag(CodecID.pcmuLaw)
                    Text("Raw PCM (double bandwidth)").tag(CodecID.pcm16)
                }
                Text("Takes effect the next time you start a session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Boat") {
                LabeledContent("Name", value: boatStore.boat?.name ?? "Not paired")
                LabeledContent("Length") {
                    Stepper("\(Int(settings.boatLengthMeters)) m", value: $settings.boatLengthMeters, in: 4...40, step: 1)
                }
                Text("Used to suggest an anchor alarm radius that allows for how far the boat can lie from the anchor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Use Signal K", isOn: $settings.signalKEnabled)
                if settings.signalKEnabled {
                    TextField("Host", text: $settings.signalKHost)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    LabeledContent("Port", value: String(settings.signalKPort))
                    LabeledContent("Status", value: model.signalK.isConnected ? "Connected" : "Not connected")
                }
            } header: {
                Text("Boat instruments")
            } footer: {
                Text("If the boat's Signal K server is reachable, Foredeck uses its GPS for the anchor position — it is mounted better than a phone in a pocket — and shows live depth.")
            }

            Section("Display") {
                Toggle("Night mode", isOn: $settings.nightMode)
            }

            Section {
                Button("Unpair this boat", role: .destructive) { confirmUnpair = true }
            } footer: {
                Text("You will need the boat name and code again to rejoin.")
            }
        }
        .confirmationDialog("Unpair this boat?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) {
                model.endSession()
                boatStore.unpair()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
