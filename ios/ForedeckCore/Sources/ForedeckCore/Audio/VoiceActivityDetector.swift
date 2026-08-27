import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Decides, frame by frame, whether the microphone is picking up someone
/// talking or just the boat.
///
/// The marine case is what shapes this. Wind across a microphone is loud,
/// broadband and near-continuous, so a fixed threshold either gates out speech
/// on a breezy day or transmits a permanent roar on a calm one. So the floor
/// adapts: it rises slowly (a gust should not be mistaken for the new normal
/// fast enough to swallow the next word) and falls quickly (once the gust
/// passes we want sensitivity straight back). An absolute floor underneath
/// stops a very quiet cabin from making the gate hair-trigger.
public struct VoiceActivityDetector: Sendable {
    public struct Config: Sendable {
        public var frameDuration: Double = 0.020
        /// Keep transmitting this long after level drops. Without it the tails
        /// of words get clipped, which is exactly when "cast off" turns into
        /// "cast".
        public var hangover: Double = 0.4
        /// Consecutive loud frames needed to open. Rejects winch clanks and
        /// halyard slap without noticeably delaying speech.
        public var attackFrames: Int = 2
        /// 0 = only loud clear speech opens the gate, 1 = very sensitive.
        /// Surfaced in settings: a 30-knot afternoon wants a different value
        /// from a quiet anchorage, and no default gets both right.
        public var sensitivity: Double = 0.5
        public var noiseRiseCoefficient: Double = 0.02
        public var noiseFallCoefficient: Double = 0.30
        public var absoluteFloorDBFS: Double = -52
        /// Where the noise floor starts before it has heard anything.
        ///
        /// Deliberately not seeded from the first frame: if the app is opened
        /// mid-sentence, seeding from a loud frame teaches the detector that
        /// speech is background and the gate never opens again. Starting
        /// conservatively low means a genuinely noisy deck takes a second or
        /// two to learn, erring towards transmitting -- the right direction to
        /// err when the word being clipped might be "stop".
        public var initialFloorDBFS: Double = -70

        public init() {}
    }

    public private(set) var config: Config
    public private(set) var isSpeaking = false
    public private(set) var noiseFloorDBFS: Double
    public private(set) var lastLevelDBFS: Double = -140
    /// True on the single frame where the gate closed, so the packetiser can
    /// mark the end of the talk spurt.
    public private(set) var didCloseThisFrame = false

    private var hangoverRemaining: Double = 0
    private var loudRun = 0

    public init(config: Config = Config()) {
        self.config = config
        self.noiseFloorDBFS = config.initialFloorDBFS
    }

    public mutating func update(config: Config) {
        self.config = config
    }

    /// Margin above the noise floor that counts as speech.
    public var marginDB: Double {
        let clamped = min(max(config.sensitivity, 0), 1)
        return 3.0 + (1.0 - clamped) * 15.0
    }

    public var effectiveFloorDBFS: Double {
        let clamped = min(max(config.sensitivity, 0), 1)
        return config.absoluteFloorDBFS + (1.0 - clamped) * 10.0
    }

    public var thresholdDBFS: Double {
        max(noiseFloorDBFS + marginDB, effectiveFloorDBFS)
    }

    @discardableResult
    public mutating func process(frameRMS: Float) -> Bool {
        let level = Self.decibels(fromRMS: frameRMS)
        lastLevelDBFS = level
        didCloseThisFrame = false

        let isLoud = level > thresholdDBFS
        loudRun = isLoud ? loudRun + 1 : 0

        if isSpeaking {
            if isLoud {
                hangoverRemaining = config.hangover
            } else {
                hangoverRemaining -= config.frameDuration
                if hangoverRemaining <= 0 {
                    isSpeaking = false
                    didCloseThisFrame = true
                }
            }
        } else if loudRun >= config.attackFrames {
            isSpeaking = true
            hangoverRemaining = config.hangover
        }

        // Only learn the noise floor while the gate is shut, otherwise speech
        // teaches the detector that speech is background.
        if !isSpeaking {
            let coefficient = level < noiseFloorDBFS ? config.noiseFallCoefficient : config.noiseRiseCoefficient
            noiseFloorDBFS += (level - noiseFloorDBFS) * coefficient
        }

        return isSpeaking
    }

    public mutating func reset() {
        isSpeaking = false
        hangoverRemaining = 0
        loudRun = 0
        noiseFloorDBFS = config.initialFloorDBFS
        lastLevelDBFS = -140
        didCloseThisFrame = false
    }

    public static func decibels(fromRMS rms: Float) -> Double {
        20.0 * log10(max(Double(rms), 1e-7))
    }

    public static func rms(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Double = 0
        for sample in samples { sum += Double(sample) * Double(sample) }
        return Float((sum / Double(samples.count)).squareRoot())
    }

    public static func rms(of samples: [Int16]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Double = 0
        for sample in samples {
            let normalised = Double(sample) / 32768.0
            sum += normalised * normalised
        }
        return Float((sum / Double(samples.count)).squareRoot())
    }
}
