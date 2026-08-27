import AVFoundation
import ForedeckCore

protocol AudioEngineDelegate: AnyObject {
    /// An encoded frame ready for the transport.
    func audioEngine(_ engine: AudioEngine, didEncode frame: Data)
    /// Local voice-activity state changed; worth telling the crew's screens.
    func audioEngine(_ engine: AudioEngine, didChangeSpeaking speaking: Bool)
    /// Throttled microphone level in dBFS for the input meter.
    func audioEngine(_ engine: AudioEngine, didUpdateInputLevel dbfs: Double)
    func audioEngine(_ engine: AudioEngine, didFail message: String)
}

/// Capture, encode, mix and play.
///
/// The one decision everything else rests on is voice processing. Two phones on
/// speaker within earshot of each other, both with open mics, is an acoustic
/// feedback loop; without hardware echo cancellation the whole idea does not
/// work at all. `setVoiceProcessingEnabled` switches AVAudioEngine to Apple's
/// voice-processing IO unit, which brings echo cancellation, noise suppression
/// and automatic gain control -- all tuned for exactly this case. It is not an
/// optimisation, it is the load-bearing wall.
final class AudioEngine: @unchecked Sendable {
    // Unchecked because every mutable field is confined to `audioQueue` and the
    // public surface is setter methods that hop onto it. The compiler cannot
    // see that; the queue discipline is the invariant.
    static let sampleRate: Double = 16_000
    static let frameDuration: Double = 0.020
    static let samplesPerFrame = Int(sampleRate * frameDuration)  // 320
    /// Frames kept queued on each player node. Three is 60 ms: enough that a
    /// late pump tick does not cause a gap, little enough to stay responsive.
    static let playbackLeadFrames = 3

    weak var delegate: AudioEngineDelegate?

    // Everything below is touched only on `audioQueue`. The public surface is
    // setter methods rather than properties precisely so that stays true: the
    // UI sets talk mode on the main thread while the capture callback reads it
    // fifty times a second, and a plain property would be a data race.
    private var isRunning = false
    private var isSpeaking = false
    private var talkMode: TalkMode = .openMic
    private var isPushToTalkHeld = false
    private var levelFrameCounter = 0

    func setTalkMode(_ mode: TalkMode) {
        audioQueue.async {
            guard mode != self.talkMode else { return }
            self.talkMode = mode
            self.detector.reset()
            self.finishSpurtIfNeeded()
        }
    }

    func setPushToTalkHeld(_ held: Bool) {
        audioQueue.async {
            guard held != self.isPushToTalkHeld else { return }
            self.isPushToTalkHeld = held
            if !held { self.finishSpurtIfNeeded() }
        }
    }

    func setVADSensitivity(_ sensitivity: Double) {
        audioQueue.async {
            var config = self.detector.config
            config.sensitivity = sensitivity
            self.detector.update(config: config)
        }
    }

    private let engine = AVAudioEngine()
    private let audioQueue = DispatchQueue(label: "com.foredeck.audio")
    private let processingFormat: AVAudioFormat
    private var encoder: WireCodec
    private var detector = VoiceActivityDetector()

    private var sinks: [PeerHandle: PeerAudioSink] = [:]
    private var converter: AVAudioConverter?
    private var captureAccumulator: [Float] = []
    private var sequence: UInt16 = 0
    private var timestamp: UInt32 = 0
    private var wasTransmitting = false
    private var pumpTimer: DispatchSourceTimer?

    init(codec: CodecID = .pcmuLaw) {
        self.processingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        )!
        self.encoder = CodecFactory.make(codec) ?? MuLawCodec()

        var config = VoiceActivityDetector.Config()
        config.frameDuration = Self.frameDuration
        self.detector = VoiceActivityDetector(config: config)
    }

    // MARK: - Lifecycle

    func start() {
        audioQueue.async {
            guard !self.isRunning else { return }
            do {
                try self.configureSession()
                try self.configureEngine()
                try self.engine.start()
                for sink in self.sinks.values { sink.player.play() }
                self.startPump()
                self.isRunning = true
            } catch {
                self.delegate?.audioEngine(self, didFail: error.localizedDescription)
            }
        }
    }

    func stop() {
        audioQueue.async {
            guard self.isRunning else { return }
            self.pumpTimer?.cancel()
            self.pumpTimer = nil
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
            for sink in self.sinks.values { sink.player.stop() }
            self.captureAccumulator.removeAll()
            self.detector.reset()
            self.updateSpeakingState(false)
            self.isRunning = false
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            #endif
        }
    }

    private func configureSession() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // .voiceChat is what asks for the echo-cancelling signal path.
        // .defaultToSpeaker matters on deck: without it the audio goes to the
        // earpiece and is inaudible the moment the phone leaves your ear.
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
        )
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(Self.frameDuration)
        try session.setActive(true, options: [])
        #endif
    }

    private func configureEngine() throws {
        let input = engine.inputNode
        // Must be set before the graph is built and the engine started.
        try input.setVoiceProcessingEnabled(true)
        try engine.outputNode.setVoiceProcessingEnabled(true)

        // Touching mainMixerNode instantiates it, which has to happen before
        // player nodes are connected to it.
        _ = engine.mainMixerNode

        for sink in sinks.values { attach(sink) }

        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw AudioEngineError.noInput
        }
        converter = AVAudioConverter(from: inputFormat, to: processingFormat)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.audioQueue.async { self?.capture(buffer) }
        }
    }

    private func startPump() {
        let timer = DispatchSource.makeTimerSource(queue: audioQueue)
        timer.schedule(deadline: .now(), repeating: Self.frameDuration, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            for sink in self.sinks.values {
                sink.pump(leadFrames: Self.playbackLeadFrames)
            }
        }
        timer.resume()
        pumpTimer = timer
    }

    // MARK: - Peers

    func addPeer(_ handle: PeerHandle) {
        audioQueue.async {
            guard self.sinks[handle] == nil else { return }
            let sink = PeerAudioSink(
                handle: handle,
                format: self.processingFormat,
                samplesPerFrame: Self.samplesPerFrame,
                frameDuration: Self.frameDuration
            )
            self.sinks[handle] = sink
            if self.isRunning {
                self.attach(sink)
                sink.player.play()
            }
        }
    }

    func removePeer(_ handle: PeerHandle) {
        audioQueue.async {
            guard let sink = self.sinks.removeValue(forKey: handle) else { return }
            sink.player.stop()
            if self.engine.attachedNodes.contains(sink.player) {
                self.engine.detach(sink.player)
            }
        }
    }

    func setVolume(_ volume: Float, for handle: PeerHandle) {
        audioQueue.async { self.sinks[handle]?.volume = volume }
    }

    func setMuted(_ muted: Bool, for handle: PeerHandle) {
        audioQueue.async { self.sinks[handle]?.isMuted = muted }
    }

    func receive(audio data: Data, from handle: PeerHandle, arrivalTime: TimeInterval) {
        audioQueue.async {
            self.sinks[handle]?.accept(data, arrivalTime: arrivalTime)
        }
    }

    /// Snapshot for the roster's link-quality readout.
    func linkQuality(completion: @escaping ([PeerHandle: LinkQuality]) -> Void) {
        audioQueue.async {
            var result: [PeerHandle: LinkQuality] = [:]
            for (handle, sink) in self.sinks {
                let stats = sink.statistics
                result[handle] = LinkQuality(
                    bufferedDelay: sink.bufferedDelay,
                    concealedFrames: stats.concealed,
                    underruns: stats.underruns,
                    receivedFrames: stats.received
                )
            }
            completion(result)
        }
    }

    private func attach(_ sink: PeerAudioSink) {
        guard !engine.attachedNodes.contains(sink.player) else { return }
        engine.attach(sink.player)
        engine.connect(sink.player, to: engine.mainMixerNode, format: processingFormat)
    }

    // MARK: - Capture

    private func capture(_ buffer: AVAudioPCMBuffer) {
        captureAccumulator.append(contentsOf: resample(buffer))

        while captureAccumulator.count >= Self.samplesPerFrame {
            let frame = Array(captureAccumulator.prefix(Self.samplesPerFrame))
            captureAccumulator.removeFirst(Self.samplesPerFrame)
            process(frame: frame)
        }
    }

    private func resample(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let converter else { return [] }

        let ratio = processingFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: capacity) else { return [] }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, let channel = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }

    private func process(frame: [Float]) {
        let level = VoiceActivityDetector.rms(of: frame)

        // The input meter is the only way a user can tell "nobody can hear me"
        // apart from "nobody is answering". Every fifth frame is 100 ms, which
        // looks live without waking SwiftUI fifty times a second.
        levelFrameCounter += 1
        if levelFrameCounter >= 5 {
            levelFrameCounter = 0
            delegate?.audioEngine(self, didUpdateInputLevel: VoiceActivityDetector.decibels(fromRMS: level))
        }

        let detected = detector.process(frameRMS: level)

        let shouldTransmit: Bool
        var flags: AudioPacketFlags = []
        switch talkMode {
        case .openMic:
            shouldTransmit = detected
        case .pushToTalk:
            shouldTransmit = isPushToTalkHeld
            flags.insert(.pushToTalk)
        }

        // The media timestamp advances whether we transmit or not, so a
        // receiver measuring the gap between spurts sees real elapsed time
        // rather than a stream that appears continuous.
        let frameTimestamp = timestamp
        timestamp = timestamp &+ UInt32(frame.count)

        if shouldTransmit {
            flags.insert(.speaking)
            emit(frame: frame, flags: flags, timestamp: frameTimestamp)
        } else if wasTransmitting {
            // One final frame marking the end of the spurt, so the far side
            // releases its buffer instead of concealing its way to silence.
            flags.insert(.endOfSpurt)
            emit(frame: frame, flags: flags, timestamp: frameTimestamp)
        }

        wasTransmitting = shouldTransmit
        updateSpeakingState(shouldTransmit)
    }

    private func emit(frame: [Float], flags: AudioPacketFlags, timestamp: UInt32) {
        let packet = AudioPacket(
            codec: encoder.codecID,
            flags: flags,
            sequence: sequence,
            timestamp: timestamp,
            payload: encoder.encode(frame)
        )
        sequence = sequence &+ 1
        delegate?.audioEngine(self, didEncode: packet.encoded())
    }

    private func finishSpurtIfNeeded() {
        guard wasTransmitting else { return }
        wasTransmitting = false
        emit(
            frame: [Float](repeating: 0, count: Self.samplesPerFrame),
            flags: [.endOfSpurt],
            timestamp: timestamp
        )
        updateSpeakingState(false)
    }

    private func updateSpeakingState(_ speaking: Bool) {
        guard speaking != isSpeaking else { return }
        isSpeaking = speaking
        delegate?.audioEngine(self, didChangeSpeaking: speaking)
    }
}

struct LinkQuality: Equatable {
    var bufferedDelay: Double
    var concealedFrames: Int
    var underruns: Int
    var receivedFrames: Int

    /// Rough health for the roster dot. Deliberately coarse: a number nobody
    /// can act on is worse than a colour.
    var isHealthy: Bool {
        guard receivedFrames > 50 else { return true }
        return Double(concealedFrames) / Double(receivedFrames) < 0.05
    }
}

enum AudioEngineError: LocalizedError {
    case noInput

    var errorDescription: String? {
        switch self {
        case .noInput:
            return "No microphone input is available."
        }
    }
}
