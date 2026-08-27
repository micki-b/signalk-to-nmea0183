import AVFoundation
import ForedeckCore

/// One remote talker's path from the network to the speaker.
///
/// Each peer gets its own player node feeding the main mixer, which is what
/// makes the duplex real: two people talking at once are genuinely mixed rather
/// than one winning. It also makes per-peer volume and mute a property set
/// rather than a signal-processing problem.
final class PeerAudioSink {
    let handle: PeerHandle
    let player = AVAudioPlayerNode()

    private let format: AVAudioFormat
    private let samplesPerFrame: Int
    private let jitterBuffer: JitterBuffer
    private var decoders: [CodecID: WireCodec] = [:]
    private var unsupportedCodecs: Set<CodecID> = []
    private let lock = NSLock()
    private var scheduledFrames = 0
    private var concealmentRun = 0

    private(set) var isSpeaking = false
    private(set) var lastPacketAt: TimeInterval = 0

    var volume: Float = 1.0 {
        didSet { player.volume = isMuted ? 0 : volume }
    }

    var isMuted = false {
        didSet { player.volume = isMuted ? 0 : volume }
    }

    init(handle: PeerHandle, format: AVAudioFormat, samplesPerFrame: Int, frameDuration: Double) {
        self.handle = handle
        self.format = format
        self.samplesPerFrame = samplesPerFrame

        var config = JitterBufferConfig()
        config.frameDuration = frameDuration
        self.jitterBuffer = JitterBuffer(sampleRate: format.sampleRate, config: config)
    }

    var statistics: JitterBufferStats { jitterBuffer.stats }
    var bufferedDelay: Double { jitterBuffer.bufferedDelay }

    func accept(_ data: Data, arrivalTime: TimeInterval) {
        guard let packet = AudioPacket(decoding: data) else { return }
        lastPacketAt = arrivalTime
        isSpeaking = packet.isSpeaking
        jitterBuffer.push(packet, arrivalTime: arrivalTime)
    }

    /// Keep the player node's queue topped up to `leadFrames`.
    ///
    /// Always scheduling something, silence included, keeps the node running
    /// and its timing stable. Letting it drain and restart costs a hiccup at
    /// the start of every sentence, which is exactly the wrong place for one.
    func pump(leadFrames: Int) {
        while pendingFrames < leadFrames {
            let samples: [Float]

            switch jitterBuffer.pop() {
            case .frame(let packet):
                concealmentRun = 0
                samples = decode(packet)

            case .concealed(let packet):
                concealmentRun += 1
                // Fade each successive repeat, so a dropout dies away rather
                // than turning into a buzz.
                let gain = max(0, 1.0 - Float(concealmentRun) / 8.0)
                samples = decode(packet).map { $0 * gain }

            case .silence:
                concealmentRun = 0
                samples = [Float](repeating: 0, count: samplesPerFrame)
            }

            schedule(samples)
        }
    }

    func reset() {
        jitterBuffer.reset()
        concealmentRun = 0
        isSpeaking = false
    }

    private var pendingFrames: Int {
        lock.lock()
        defer { lock.unlock() }
        return scheduledFrames
    }

    private func decoder(for codec: CodecID) -> WireCodec? {
        if let existing = decoders[codec] { return existing }
        guard !unsupportedCodecs.contains(codec) else { return nil }
        guard let made = CodecFactory.make(codec) else {
            // Remember the refusal so we do not retry it fifty times a second.
            unsupportedCodecs.insert(codec)
            return nil
        }
        decoders[codec] = made
        return made
    }

    private func decode(_ packet: AudioPacket) -> [Float] {
        // A peer on a newer build using a codec we lack: play silence rather
        // than noise, and keep the timeline intact.
        guard let decoder = decoder(for: packet.codec) else {
            return [Float](repeating: 0, count: samplesPerFrame)
        }
        let samples = decoder.decode(packet.payload)
        return samples.isEmpty ? [Float](repeating: 0, count: samplesPerFrame) : samples
    }

    private func schedule(_ samples: [Float]) {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData
        else { return }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel[0].update(from: base, count: samples.count)
        }

        lock.lock()
        scheduledFrames += 1
        lock.unlock()

        player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.scheduledFrames -= 1
            self.lock.unlock()
        }
    }
}
