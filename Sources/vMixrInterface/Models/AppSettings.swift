import Foundation
import Combine

// REQ-033..035: system audio settings persisted to UserDefaults, applied on relaunch.
public final class AppSettings: ObservableObject {
    @Published public var sampleRate: Double {
        didSet { defaults.set(sampleRate, forKey: Keys.sampleRate) }
    }
    @Published public var sampleFrameLength: Int {
        didSet { defaults.set(sampleFrameLength, forKey: Keys.frameLength) }
    }
    @Published public var streamerCount: Int {
        didSet { defaults.set(streamerCount, forKey: Keys.streamerCount) }
    }

    private let defaults: UserDefaults

    public enum Keys {
        static let sampleRate = "sampleRate"
        static let frameLength = "sampleFrameLength"
        static let streamerCount = "streamerCount"
    }

    public static let frameLengthChoices = [512, 256, 128, 64, 32]
    public static let sampleRateChoices = [192000.0, 96000.0, 48000.0, 44100.0]
    public static let streamerCountRange = 0...8

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Keys.sampleRate) != nil {
            sampleRate = defaults.double(forKey: Keys.sampleRate)
        } else {
            sampleRate = 44100
        }
        if defaults.object(forKey: Keys.frameLength) != nil {
            sampleFrameLength = defaults.integer(forKey: Keys.frameLength)
        } else {
            sampleFrameLength = 256
        }
        if defaults.object(forKey: Keys.streamerCount) != nil {
            streamerCount = min(max(defaults.integer(forKey: Keys.streamerCount), 0), 8)
        } else {
            streamerCount = 8
        }
    }
}
