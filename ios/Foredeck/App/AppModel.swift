import Foundation
import Combine
import AVFoundation
import ForedeckCore
#if canImport(UIKit)
import UIKit
#endif

/// Coordinator. Owns the transport, the audio engine, position, the optional
/// Signal K feed and the shared anchor state, and is the only place they meet.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var crew: [CrewMember] = []
    @Published private(set) var transportState: TransportState = .idle
    @Published private(set) var anchorState: AnchorState
    @Published private(set) var isSessionActive = false
    @Published private(set) var localSpeaking = false
    @Published private(set) var inputLevelDBFS: Double = -140
    @Published var errorMessage: String?

    let settings: SettingsStore
    let boatStore: BoatStore
    let location = LocationProvider()
    let signalK = SignalKClient()
    let alarm = AlarmController()

    private let crewTransport = MultipeerTransport()
    private let audio: AudioEngine
    private let clock: LamportClock
    private var positionTimer: Timer?
    private var qualityTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(settings: SettingsStore = SettingsStore(), boatStore: BoatStore = BoatStore()) {
        self.settings = settings
        self.boatStore = boatStore
        self.clock = LamportClock(deviceID: settings.deviceID)
        self.anchorState = AnchorState.initial(deviceID: settings.deviceID)
        self.audio = AudioEngine(codec: settings.codec)

        crewTransport.delegate = self
        audio.delegate = self
        observeSettings()
        observePosition()
    }

    // MARK: - Session

    var boatName: String { boatStore.boat?.name ?? "" }
    var isPaired: Bool { boatStore.boat != nil }

    /// Signal K's fix when we have one, the phone's otherwise. The boat's own
    /// GPS is mounted somewhere sensible and is not in anyone's pocket, so it
    /// is the better anchor reference whenever it is available.
    var effectivePosition: GeoPoint? {
        signalK.position ?? location.position
    }

    var positionSource: String {
        signalK.position != nil ? "Boat GPS" : "This phone"
    }

    func startSession() {
        guard let boat = boatStore.boat, !isSessionActive else { return }

        requestMicrophonePermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.errorMessage = "Foredeck needs the microphone to work. Settings › Foredeck › Microphone."
                return
            }

            self.audio.setTalkMode(self.settings.talkMode)
            self.audio.setVADSensitivity(self.settings.vadSensitivity)
            self.audio.start()
            self.crewTransport.start(identity: self.settings.identity, boatName: boat.name, key: boat.key)

            self.location.requestAuthorization()
            self.location.start()
            self.alarm.requestPermission()

            if self.settings.signalKEnabled {
                self.signalK.connect(host: self.settings.signalKHost, port: self.settings.signalKPort)
            }

            #if canImport(UIKit)
            // Phones live on deck during a manoeuvre; a screen that sleeps
            // mid-approach is a phone nobody can reach in time.
            UIApplication.shared.isIdleTimerDisabled = true
            #endif

            self.isSessionActive = true
            self.startTimers()
        }
    }

    func endSession() {
        guard isSessionActive else { return }
        stopTimers()
        crewTransport.stop()
        audio.stop()
        location.stop()
        signalK.disconnect()
        crew.removeAll()
        transportState = .idle
        localSpeaking = false
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
        isSessionActive = false
    }

    // MARK: - Talking

    func setPushToTalk(held: Bool) {
        audio.setPushToTalkHeld(held)
    }

    func setMuted(_ muted: Bool, for member: CrewMember) {
        audio.setMuted(muted, for: member.handle)
        update(member.handle) { $0.isMuted = muted }
    }

    func setVolume(_ volume: Float, for member: CrewMember) {
        audio.setVolume(volume, for: member.handle)
        update(member.handle) { $0.volume = volume }
    }

    // MARK: - Shared anchor state

    func setMode(_ mode: CrewMode) {
        anchorState.mode = anchorState.mode.setting(mode, using: clock)
        broadcastAnchorState()
    }

    func dropAnchor(at point: GeoPoint) {
        anchorState.anchorDrop = anchorState.anchorDrop.setting(point, using: clock)
        anchorState.anchorDropTime = anchorState.anchorDropTime.setting(Date(), using: clock)
        if anchorState.alarmRadiusMeters.value <= 0 {
            let suggested = AnchorState.suggestedAlarmRadius(
                rodeMeters: anchorState.rodeMeters.value,
                boatLengthMeters: settings.boatLengthMeters
            )
            anchorState.alarmRadiusMeters = anchorState.alarmRadiusMeters.setting(suggested, using: clock)
        }
        location.clearTrack()
        broadcastAnchorState()
    }

    func weighAnchor() {
        anchorState.anchorDrop = anchorState.anchorDrop.setting(nil, using: clock)
        anchorState.anchorDropTime = anchorState.anchorDropTime.setting(nil, using: clock)
        anchorState.alarmEnabled = anchorState.alarmEnabled.setting(false, using: clock)
        alarm.acknowledge()
        broadcastAnchorState()
    }

    func setRode(_ meters: Double) {
        anchorState.rodeMeters = anchorState.rodeMeters.setting(meters, using: clock)
        broadcastAnchorState()
    }

    func setAlarmRadius(_ meters: Double) {
        anchorState.alarmRadiusMeters = anchorState.alarmRadiusMeters.setting(meters, using: clock)
        broadcastAnchorState()
    }

    func setAlarmEnabled(_ enabled: Bool) {
        anchorState.alarmEnabled = anchorState.alarmEnabled.setting(enabled, using: clock)
        if enabled {
            // Only ask for Always when the alarm is actually armed: that is the
            // one case where the reason for it is obvious to the user.
            location.requestAlwaysAuthorization()
        } else {
            alarm.acknowledge()
        }
        broadcastAnchorState()
    }

    func setDockTarget(_ point: GeoPoint?) {
        anchorState.dockTarget = anchorState.dockTarget.setting(point, using: clock)
        broadcastAnchorState()
    }

    func suggestedAlarmRadius() -> Double {
        AnchorState.suggestedAlarmRadius(
            rodeMeters: anchorState.rodeMeters.value,
            boatLengthMeters: settings.boatLengthMeters
        )
    }

    private func broadcastAnchorState() {
        send(.anchorState(anchorState))
    }

    private func send(_ message: ControlMessage) {
        let envelope = ControlEnvelope(
            sender: settings.identity,
            stamp: clock.tick(),
            message: message
        )
        crewTransport.sendControl(envelope)
    }

    // MARK: - Timers

    private func startTimers() {
        let position = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.broadcastPosition() }
        }
        RunLoop.main.add(position, forMode: .common)
        positionTimer = position

        let quality = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLinkQuality() }
        }
        RunLoop.main.add(quality, forMode: .common)
        qualityTimer = quality
    }

    private func stopTimers() {
        positionTimer?.invalidate()
        positionTimer = nil
        qualityTimer?.invalidate()
        qualityTimer = nil
    }

    private func broadcastPosition() {
        guard let point = effectivePosition else { return }
        send(.position(point, accuracyMeters: location.horizontalAccuracy, at: Date()))
    }

    private func refreshLinkQuality() {
        audio.linkQuality { [weak self] quality in
            Task { @MainActor in
                guard let self else { return }
                for index in self.crew.indices {
                    self.crew[index].quality = quality[self.crew[index].handle]
                }
            }
        }
    }

    // MARK: - Observation

    private func observeSettings() {
        settings.$talkMode
            .sink { [weak self] mode in self?.audio.setTalkMode(mode) }
            .store(in: &cancellables)

        settings.$vadSensitivity
            .sink { [weak self] sensitivity in self?.audio.setVADSensitivity(sensitivity) }
            .store(in: &cancellables)

        settings.$signalKEnabled
            .sink { [weak self] enabled in
                guard let self, self.isSessionActive else { return }
                if enabled {
                    self.signalK.connect(host: self.settings.signalKHost, port: self.settings.signalKPort)
                } else {
                    self.signalK.disconnect()
                }
            }
            .store(in: &cancellables)
    }

    private func observePosition() {
        location.$position
            .compactMap { $0 }
            .sink { [weak self] _ in self?.evaluateAlarm() }
            .store(in: &cancellables)

        signalK.$position
            .compactMap { $0 }
            .sink { [weak self] _ in self?.evaluateAlarm() }
            .store(in: &cancellables)
    }

    private func evaluateAlarm() {
        guard let point = effectivePosition, let distance = anchorState.dragDistance(from: point) else { return }

        if anchorState.isOutsideAlarmRadius(point) {
            let wasFiring = alarm.isFiring
            alarm.fire(distanceMeters: distance, radiusMeters: anchorState.alarmRadiusMeters.value)
            // Tell the rest of the crew once, not every fix.
            if !wasFiring {
                send(.anchorAlarm(distanceMeters: distance, at: Date()))
            }
        } else if alarm.isFiring {
            alarm.acknowledge()
            send(.anchorAlarmCleared)
        }
    }

    // MARK: - Roster helpers

    private func update(_ handle: PeerHandle, _ mutation: (inout CrewMember) -> Void) {
        guard let index = crew.firstIndex(where: { $0.handle == handle }) else { return }
        mutation(&crew[index])
    }

    private func requestMicrophonePermission(_ completion: @escaping (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                Task { @MainActor in completion(granted) }
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                Task { @MainActor in completion(granted) }
            }
        }
    }
}

// MARK: - CrewTransportDelegate

extension AppModel: CrewTransportDelegate {
    nonisolated func transport(_ transport: CrewTransport, didChange state: TransportState) {
        Task { @MainActor in
            self.transportState = state
            if case .failed(let message) = state {
                self.errorMessage = message
            }
        }
    }

    nonisolated func transport(_ transport: CrewTransport, didConnect peer: PeerHandle) {
        Task { @MainActor in
            self.audio.addPeer(peer)
            if !self.crew.contains(where: { $0.handle == peer }) {
                // Placeholder until the hello arrives, so the tile appears the
                // instant the link is up rather than a beat later.
                let placeholder = CrewIdentity(deviceID: peer.rawValue, displayName: "", role: .crew)
                self.crew.append(CrewMember(handle: peer, identity: placeholder))
            }
            self.send(.hello(self.settings.identity))
            self.send(.requestSnapshot)
        }
    }

    nonisolated func transport(_ transport: CrewTransport, didDisconnect peer: PeerHandle) {
        Task { @MainActor in
            self.audio.removePeer(peer)
            self.crew.removeAll { $0.handle == peer }
        }
    }

    nonisolated func transport(_ transport: CrewTransport, didReceiveAudio data: Data, from peer: PeerHandle, arrivalTime: Double) {
        // Straight to the engine. Hopping to the main actor first would add
        // scheduling jitter to the very measurement the buffer adapts on.
        audio.receive(audio: data, from: peer, arrivalTime: arrivalTime)
    }

    nonisolated func transport(_ transport: CrewTransport, didReceiveControl envelope: ControlEnvelope, from peer: PeerHandle) {
        Task { @MainActor in
            self.clock.observe(envelope.stamp)
            self.handle(envelope, from: peer)
        }
    }

    private func handle(_ envelope: ControlEnvelope, from peer: PeerHandle) {
        switch envelope.message {
        case .hello(let identity):
            if let index = crew.firstIndex(where: { $0.handle == peer }) {
                crew[index].identity = identity
            } else {
                crew.append(CrewMember(handle: peer, identity: identity))
            }

        case .speaking(let speaking):
            update(peer) { $0.isSpeaking = speaking }

        case .position(let point, _, let date):
            update(peer) {
                $0.position = point
                $0.positionUpdatedAt = date
            }

        case .anchorState(let incoming):
            clock.observe(incoming.highestStamp)
            anchorState = anchorState.merged(with: incoming)
            evaluateAlarm()

        case .requestSnapshot:
            let reply = ControlEnvelope(
                sender: settings.identity,
                stamp: clock.tick(),
                message: .anchorState(anchorState)
            )
            crewTransport.sendControl(reply, to: peer)

        case .anchorAlarm(let distance, _):
            // Somebody else's phone noticed first. Wake this one too.
            alarm.fire(distanceMeters: distance, radiusMeters: anchorState.alarmRadiusMeters.value)

        case .anchorAlarmCleared:
            alarm.acknowledge()

        case .goodbye:
            audio.removePeer(peer)
            crew.removeAll { $0.handle == peer }
        }
    }
}

// MARK: - AudioEngineDelegate

extension AppModel: AudioEngineDelegate {
    nonisolated func audioEngine(_ engine: AudioEngine, didEncode frame: Data) {
        crewTransport.sendAudio(frame)
    }

    nonisolated func audioEngine(_ engine: AudioEngine, didChangeSpeaking speaking: Bool) {
        Task { @MainActor in
            self.localSpeaking = speaking
            self.send(.speaking(speaking))
        }
    }

    nonisolated func audioEngine(_ engine: AudioEngine, didUpdateInputLevel dbfs: Double) {
        Task { @MainActor in self.inputLevelDBFS = dbfs }
    }

    nonisolated func audioEngine(_ engine: AudioEngine, didFail message: String) {
        Task { @MainActor in self.errorMessage = message }
    }
}
