import Foundation

public struct JitterBufferConfig: Sendable {
    /// Duration of one media frame. Must match the sender's packetiser.
    public var frameDuration: Double = 0.020
    /// Never buffer less than this. Two frames (40 ms) is about the floor
    /// before ordinary WiFi scheduling jitter starts causing dropouts.
    public var minDepthFrames: Int = 2
    /// Never buffer more than this. Six frames (120 ms) of buffering plus
    /// capture and encode delay is around the limit of what still feels like a
    /// conversation rather than a radio call.
    public var maxDepthFrames: Int = 6
    public var initialDepthFrames: Int = 3
    /// How many consecutive frames we are willing to conceal before giving up
    /// and outputting silence. Repeating one frame for more than ~200 ms
    /// sounds far worse than a gap.
    public var maxConcealedFrames: Int = 10
    /// A forward jump larger than this means the sender restarted or we were
    /// suspended; resynchronise instead of concealing thousands of frames.
    public var resyncThresholdFrames: Int = 40
    /// Frames of trouble-free playback before we allow the buffer to shrink.
    /// Shrinking is deliberately far slower than growing: a buffer that
    /// oscillates is audible, one that sits slightly too deep is not.
    public var shrinkAfterCleanFrames: Int = 250

    public init() {}
}

public enum JitterBufferOutput: Equatable, Sendable {
    /// A real frame, in order.
    case frame(AudioPacket)
    /// A repeat of the previous frame standing in for a lost one. The caller is
    /// expected to attenuate successive concealments so a dropout fades rather
    /// than buzzing.
    case concealed(AudioPacket)
    /// Nothing to play: still filling, underrun, or the talker stopped.
    case silence
}

public struct JitterBufferStats: Equatable, Sendable {
    public var received = 0
    public var duplicates = 0
    /// Arrived after we had already played past their slot.
    public var late = 0
    public var concealed = 0
    public var underruns = 0
    public var resyncs = 0

    public init() {}
}

/// Reorders, de-duplicates and paces one remote talker's audio.
///
/// This is the piece a WebRTC-based transport would have given us for free, and
/// it is the main cost of choosing Multipeer Connectivity. It is also entirely
/// platform-free arithmetic, which is why it lives here and is unit tested
/// rather than being discovered to be wrong halfway through a docking manoeuvre.
///
/// Not thread safe. Each instance is owned by the audio pump.
public final class JitterBuffer {
    public private(set) var config: JitterBufferConfig
    public private(set) var targetDepth: Int
    /// RFC 3550 style smoothed interarrival jitter, in seconds.
    public private(set) var jitterEstimate: Double = 0
    public private(set) var stats = JitterBufferStats()

    private let sampleRate: Double
    private var packets: [UInt16: AudioPacket] = [:]
    private var nextSequence: UInt16 = 0
    private var newestSequence: UInt16 = 0
    private var haveStream = false
    private var playing = false
    private var lastFrame: AudioPacket?
    private var concealedRun = 0
    private var cleanRun = 0
    private var previousArrival: Double?
    private var previousTimestamp: UInt32?

    public init(sampleRate: Double, config: JitterBufferConfig = JitterBufferConfig()) {
        self.sampleRate = sampleRate
        self.config = config
        self.targetDepth = min(max(config.initialDepthFrames, config.minDepthFrames), config.maxDepthFrames)
    }

    public var pendingFrameCount: Int { packets.count }
    public var isPlaying: Bool { playing }

    /// Current buffering delay in seconds, for the UI's link-quality readout.
    public var bufferedDelay: Double { Double(targetDepth) * config.frameDuration }

    public func push(_ packet: AudioPacket, arrivalTime: Double) {
        stats.received += 1

        guard haveStream else {
            haveStream = true
            nextSequence = packet.sequence
            newestSequence = packet.sequence
            packets[packet.sequence] = packet
            previousArrival = arrivalTime
            previousTimestamp = packet.timestamp
            return
        }

        // Already played past this slot: too late to be useful.
        if SerialNumber16.isNewer(nextSequence, than: packet.sequence) {
            stats.late += 1
            return
        }
        if packets[packet.sequence] != nil {
            stats.duplicates += 1
            return
        }

        // Only frames we are actually going to play should shape the estimate.
        // Letting duplicates and late arrivals in makes the buffer deepen in
        // response to conditions it is already handling.
        updateJitterEstimate(for: packet, arrivalTime: arrivalTime)

        packets[packet.sequence] = packet
        if SerialNumber16.isNewer(packet.sequence, than: newestSequence) {
            newestSequence = packet.sequence
        }

        if SerialNumber16.distance(from: nextSequence, to: newestSequence) > config.resyncThresholdFrames {
            resync()
        }
    }

    public func pop() -> JitterBufferOutput {
        guard haveStream else { return .silence }

        if !playing {
            guard packets.count >= targetDepth else { return .silence }
            playing = true
        }

        if let packet = packets.removeValue(forKey: nextSequence) {
            nextSequence &+= 1
            lastFrame = packet
            concealedRun = 0
            cleanRun += 1
            // The talker stopped. Re-buffer for the next spurt instead of
            // concealing our way into silence -- and the pause is free
            // headroom to re-establish depth without anyone hearing it.
            if packet.flags.contains(.endOfSpurt) {
                playing = false
            }
            considerShrinking()
            return .frame(packet)
        }

        if packets.isEmpty {
            playing = false
            cleanRun = 0
            stats.underruns += 1
            grow()
            return .silence
        }

        // A hole with newer frames behind it: conceal and move on.
        nextSequence &+= 1
        concealedRun += 1
        cleanRun = 0
        stats.concealed += 1
        if let last = lastFrame, concealedRun <= config.maxConcealedFrames {
            return .concealed(last)
        }
        return .silence
    }

    /// Forget everything. Used when a peer drops out and rejoins.
    public func reset() {
        packets.removeAll()
        haveStream = false
        playing = false
        lastFrame = nil
        concealedRun = 0
        cleanRun = 0
        previousArrival = nil
        previousTimestamp = nil
        jitterEstimate = 0
        targetDepth = min(max(config.initialDepthFrames, config.minDepthFrames), config.maxDepthFrames)
    }

    // MARK: - Adaptation

    private func updateJitterEstimate(for packet: AudioPacket, arrivalTime: Double) {
        defer {
            previousArrival = arrivalTime
            previousTimestamp = packet.timestamp
        }
        guard let previousArrival, let previousTimestamp else { return }

        // Signed difference so a wrapped 32-bit timestamp still yields a sane
        // delta rather than a four-billion-sample jump.
        let sampleDelta = Double(Int32(bitPattern: packet.timestamp &- previousTimestamp))
        let expected = sampleDelta / sampleRate
        let actual = arrivalTime - previousArrival
        let deviation = abs(actual - expected)
        jitterEstimate += (deviation - jitterEstimate) / 16.0

        let wanted = depthForCurrentJitter()
        if wanted > targetDepth {
            targetDepth = wanted
            cleanRun = 0
        }
    }

    private func depthForCurrentJitter() -> Int {
        let frames = Int((2.0 * jitterEstimate / config.frameDuration).rounded(.up))
        return min(max(frames + config.minDepthFrames, config.minDepthFrames), config.maxDepthFrames)
    }

    private func grow() {
        targetDepth = min(config.maxDepthFrames, targetDepth + 1)
    }

    private func considerShrinking() {
        guard cleanRun >= config.shrinkAfterCleanFrames else { return }
        guard targetDepth > config.minDepthFrames, targetDepth > depthForCurrentJitter() else { return }
        targetDepth -= 1
        cleanRun = 0
    }

    private func resync() {
        stats.resyncs += 1
        let lead = UInt16(max(0, targetDepth - 1))
        let horizon = newestSequence &- lead
        for key in packets.keys where SerialNumber16.isNewer(horizon, than: key) {
            packets.removeValue(forKey: key)
        }
        // Resume at the oldest frame we actually kept rather than at the
        // horizon. Landing on an empty slot would make us emit a run of
        // silence before the first real frame, for no benefit.
        var oldest: UInt16?
        for key in packets.keys {
            if let current = oldest {
                if SerialNumber16.isNewer(current, than: key) { oldest = key }
            } else {
                oldest = key
            }
        }
        nextSequence = oldest ?? horizon
        playing = false
        concealedRun = 0
        cleanRun = 0
    }
}
