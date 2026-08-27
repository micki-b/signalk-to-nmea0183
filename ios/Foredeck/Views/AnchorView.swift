import SwiftUI
import MapKit
import ForedeckCore

/// The shared picture. Every crew member sees the same anchor, the same circle
/// and the same numbers, and any of them can change them.
struct AnchorView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var settings: SettingsStore
    @State private var camera: MapCameraPosition = .automatic

    private var night: Bool { settings.nightMode }
    private var state: AnchorState { model.anchorState }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                modePicker
                map.frame(height: 320).clipShape(RoundedRectangle(cornerRadius: Deck.corner))

                if let depth = model.signalK.depth {
                    instrumentRow(depth: depth)
                }

                if state.mode.value == .anchor {
                    anchorControls
                } else {
                    dockControls
                }
            }
            .padding(20)
        }
        .background(Deck.background(night: night).ignoresSafeArea())
        .alert("Anchor drag alarm", isPresented: alarmBinding) {
            Button("Acknowledge", role: .cancel) { model.alarm.acknowledge() }
        } message: {
            Text(String(format: "%.0f m from the drop point.", model.alarm.lastDistance))
        }
    }

    private var alarmBinding: Binding<Bool> {
        Binding(get: { model.alarm.isFiring }, set: { if !$0 { model.alarm.acknowledge() } })
    }

    private var modePicker: some View {
        Picker("Mode", selection: Binding(
            get: { state.mode.value },
            set: { model.setMode($0) }
        )) {
            ForEach(CrewMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    private var map: some View {
        Map(position: $camera) {
            if let drop = state.anchorDrop.value {
                // The circle is the whole point of the picture: a distance
                // readout alone cannot tell sailing around the hook apart from
                // dragging, but a track inside or outside this can.
                MapCircle(center: drop.coordinate, radius: max(state.alarmRadiusMeters.value, 5))
                    .foregroundStyle(Deck.accent(night: night).opacity(0.12))
                    .stroke(Deck.accent(night: night), lineWidth: 2)

                Annotation("Anchor", coordinate: drop.coordinate) {
                    Image(systemName: "anchor")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Deck.primaryText(night: night))
                        .padding(6)
                        .background(Deck.surface(night: night), in: Circle())
                }
            }

            if let target = state.dockTarget.value {
                Annotation("Target", coordinate: target.coordinate) {
                    Image(systemName: "target")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Deck.warning(night: night))
                        .padding(6)
                        .background(Deck.surface(night: night), in: Circle())
                }
            }

            if model.location.track.count > 1 {
                MapPolyline(coordinates: model.location.track.map(\.coordinate))
                    .stroke(Deck.warning(night: night).opacity(0.8), lineWidth: 3)
            }

            if let here = model.effectivePosition {
                Annotation("Boat", coordinate: here.coordinate) {
                    Image(systemName: "location.north.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Deck.accent(night: night))
                }
            }

            ForEach(model.crew) { member in
                if let position = member.position {
                    Annotation(member.displayName, coordinate: position.coordinate) {
                        Circle()
                            .fill(Deck.secondaryText(night: night))
                            .frame(width: 12, height: 12)
                    }
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
    }

    private func instrumentRow(depth: Double) -> some View {
        DeckCard(night: night) {
            HStack(spacing: 24) {
                readout(title: "Depth", value: String(format: "%.1f m", depth))
                if let wind = model.signalK.apparentWindSpeed {
                    readout(title: "AWS", value: String(format: "%.1f kn", wind * 1.94384))
                }
                if let sog = model.signalK.speedOverGround {
                    readout(title: "SOG", value: String(format: "%.1f kn", sog * 1.94384))
                }
            }
        }
    }

    private func readout(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Deck.secondaryText(night: night))
            Text(value)
                .font(Deck.readout(24))
                .foregroundStyle(Deck.primaryText(night: night))
        }
    }

    // MARK: - Anchor

    @ViewBuilder
    private var anchorControls: some View {
        DeckCard(night: night) {
            VStack(alignment: .leading, spacing: 16) {
                if let here = model.effectivePosition, let distance = state.dragDistance(from: here) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("From drop point")
                            .font(.system(size: 14))
                            .foregroundStyle(Deck.secondaryText(night: night))
                        Text(String(format: "%.0f m", distance))
                            .font(Deck.readout(52))
                            .foregroundStyle(
                                distance > state.alarmRadiusMeters.value
                                    ? Deck.danger(night: night)
                                    : Deck.primaryText(night: night)
                            )
                    }
                }

                Text("Position from \(model.positionSource)")
                    .font(.system(size: 13))
                    .foregroundStyle(Deck.secondaryText(night: night))

                if state.anchorDrop.value == nil {
                    Button("Drop anchor here") {
                        guard let here = model.effectivePosition else { return }
                        model.dropAnchor(at: here)
                    }
                    .buttonStyle(DeckButtonStyle(night: night, tint: Deck.accent(night: night).opacity(0.35)))
                    .disabled(model.effectivePosition == nil)
                } else {
                    Button("Weigh anchor") {
                        model.weighAnchor()
                    }
                    .buttonStyle(DeckButtonStyle(night: night))
                }
            }
        }

        DeckCard(night: night) {
            VStack(alignment: .leading, spacing: 20) {
                stepper(
                    title: "Rode out",
                    value: state.rodeMeters.value,
                    unit: "m",
                    step: 5,
                    range: 0...200
                ) { model.setRode($0) }

                stepper(
                    title: "Alarm radius",
                    value: state.alarmRadiusMeters.value,
                    unit: "m",
                    step: 5,
                    range: 10...300
                ) { model.setAlarmRadius($0) }

                Button("Suggest from rode (\(Int(model.suggestedAlarmRadius())) m)") {
                    model.setAlarmRadius(model.suggestedAlarmRadius())
                }
                .font(.system(size: 15))
                .foregroundStyle(Deck.accent(night: night))

                Toggle(isOn: Binding(
                    get: { state.alarmEnabled.value },
                    set: { model.setAlarmEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Anchor alarm")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(Deck.primaryText(night: night))
                        Text("Wakes every phone on the boat, not just this one.")
                            .font(.system(size: 13))
                            .foregroundStyle(Deck.secondaryText(night: night))
                    }
                }
                .tint(Deck.accent(night: night))
                .disabled(state.anchorDrop.value == nil)
            }
        }
    }

    // MARK: - Dock

    @ViewBuilder
    private var dockControls: some View {
        DeckCard(night: night) {
            VStack(alignment: .leading, spacing: 16) {
                if let here = model.effectivePosition, let target = state.dockTarget.value {
                    let distance = Geo.distance(from: here, to: target)
                    let bearing = Geo.bearing(from: here, to: target)

                    HStack(alignment: .top, spacing: 32) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Distance")
                                .font(.system(size: 14))
                                .foregroundStyle(Deck.secondaryText(night: night))
                            Text(String(format: "%.0f m", distance))
                                .font(Deck.readout(52))
                                .foregroundStyle(Deck.primaryText(night: night))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Bearing")
                                .font(.system(size: 14))
                                .foregroundStyle(Deck.secondaryText(night: night))
                            Text(String(format: "%03.0f°", bearing))
                                .font(Deck.readout(52))
                                .foregroundStyle(Deck.primaryText(night: night))
                        }
                    }
                } else {
                    Text("Mark the berth, a piling, or wherever the bow needs to end up. Everyone sees the same mark and the same distance to it.")
                        .font(.system(size: 15))
                        .foregroundStyle(Deck.secondaryText(night: night))
                }

                if state.dockTarget.value == nil {
                    Button("Mark target here") {
                        guard let here = model.effectivePosition else { return }
                        model.setDockTarget(here)
                    }
                    .buttonStyle(DeckButtonStyle(night: night, tint: Deck.accent(night: night).opacity(0.35)))
                    .disabled(model.effectivePosition == nil)
                } else {
                    Button("Clear target") { model.setDockTarget(nil) }
                        .buttonStyle(DeckButtonStyle(night: night))
                }
            }
        }
    }

    private func stepper(
        title: String,
        value: Double,
        unit: String,
        step: Double,
        range: ClosedRange<Double>,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Deck.primaryText(night: night))
                Spacer()
                Text("\(Int(value)) \(unit)")
                    .font(Deck.readout(22))
                    .foregroundStyle(Deck.primaryText(night: night))
            }
            HStack(spacing: 12) {
                Button {
                    onChange(max(range.lowerBound, value - step))
                } label: {
                    Image(systemName: "minus")
                        .frame(maxWidth: .infinity, minHeight: Deck.minimumTarget)
                }
                .buttonStyle(DeckButtonStyle(night: night))

                Button {
                    onChange(min(range.upperBound, value + step))
                } label: {
                    Image(systemName: "plus")
                        .frame(maxWidth: .infinity, minHeight: Deck.minimumTarget)
                }
                .buttonStyle(DeckButtonStyle(night: night))
            }
        }
    }
}
