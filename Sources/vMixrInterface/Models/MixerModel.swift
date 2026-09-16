import Foundation
import Combine
import CoreAudio
import AudioKit

// REQ-010..015: input channel state
public struct InputChannel: Identifiable, Hashable {
    public let id: Int
    public var deviceID: AudioDeviceID
    // REQ-004/006: stable device identifier. AudioObjectIDs are volatile, so the
    // UID is the persisted source of truth and deviceID is resolved from it.
    public var deviceUID: String
    public var channelL: Int
    public var channelR: Int
    public var level: Double
    public var gainDB: Double
    public var bus: Set<BusID>

    public init(id: Int, deviceID: AudioDeviceID = 0, deviceUID: String = "",
                channelL: Int = 0, channelR: Int = 1, level: Double = 1.0,
                gainDB: Double = 0.0, bus: Set<BusID> = []) {
        self.id = id
        self.deviceID = deviceID
        self.deviceUID = deviceUID
        self.channelL = channelL
        self.channelR = channelR
        self.level = level
        self.gainDB = gainDB
        self.bus = bus
    }
}

// REQ-016..018: output channel state
public struct OutputChannel: Identifiable, Hashable {
    public let id: Int
    public var deviceID: AudioDeviceID
    public var deviceUID: String
    public var level: Double

    public init(id: Int, deviceID: AudioDeviceID = 0, deviceUID: String = "", level: Double = 1.0) {
        self.id = id
        self.deviceID = deviceID
        self.deviceUID = deviceUID
        self.level = level
    }
}

// REQ-015: bus routing targets (main + 3 aux)
public enum BusID: Int, CaseIterable, Hashable, Sendable {
    case main, aux1, aux2, aux3
    public var displayName: String {
        switch self {
        case .main: return "メイン"
        case .aux1: return "Aux 1"
        case .aux2: return "Aux 2"
        case .aux3: return "Aux 3"
        }
    }
}

public enum GainStep {
    public static let maxDB: Double = 6
    public static let minDB: Double = -60
    public static let maxLevelLinear: Double = pow(10, maxDB / 20)

    public static func levelToDB(_ level: Double) -> Double {
        level <= 0 ? minDB : max(minDB, 20 * log10(level))
    }

    public static func dbToLevel(_ db: Double) -> Double {
        db <= minDB ? 0 : min(maxLevelLinear, pow(10, db / 20))
    }
}

// REQ-004/010..022: mixer state, persisted to UserDefaults
public final class MixerModel: ObservableObject {
    @Published public var inputs: [InputChannel]
    @Published public var outputs: [OutputChannel]
    public static let inputCount = 4
    public static let outputCount = 4

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: MixerModel.storageKey),
           let decoded = try? JSONDecoder().decode(MixerState.self, from: data) {
            self.inputs = decoded.inputs.map { ch in
                var c = ch
                c.gainDB = 0
                c.level = min(max(c.level, 0), GainStep.maxLevelLinear)
                return c
            }
            self.outputs = decoded.outputs.map { ch in
                var c = ch
                c.level = min(max(c.level, 0), GainStep.maxLevelLinear)
                return c
            }
        } else {
            self.inputs = (0..<MixerModel.inputCount).map {
                InputChannel(id: $0, deviceID: 0, channelL: 0, channelR: 1,
                            level: 1.0, gainDB: 0.0, bus: [])
            }
            self.outputs = (0..<MixerModel.outputCount).map {
                OutputChannel(id: $0, deviceID: 0, level: 1.0)
            }
        }
        persist()
    }

    private static let storageKey = "mixerState.v1"

    private struct MixerState: Codable {
        var inputs: [InputChannel]
        var outputs: [OutputChannel]
    }

    public func persist() {
        let state = MixerState(inputs: inputs, outputs: outputs)
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: MixerModel.storageKey)
        }
    }

    public func input(_ index: Int) -> InputChannel { inputs[index] }
    public func output(_ index: Int) -> OutputChannel { outputs[index] }

    // REQ-004/006: resolve persisted device UIDs to the current AudioObjectIDs.
    // Runs at launch because IDs change when coreaudiod restarts. Pre-UID
    // settings (deviceUID empty) adopt the UID of the stored ID while it is
    // still valid, so an existing configuration keeps working after the upgrade.
    @MainActor
    public func resolveDevices(_ devices: DeviceManager) {
        var newInputs = inputs
        var newOutputs = outputs
        for i in newInputs.indices {
            if !newInputs[i].deviceUID.isEmpty {
                newInputs[i].deviceID = devices.device(withUID: newInputs[i].deviceUID)?.id ?? 0
            } else if newInputs[i].deviceID != 0 {
                if let d = devices.device(withID: newInputs[i].deviceID) {
                    newInputs[i].deviceUID = d.uid
                } else {
                    newInputs[i].deviceID = 0
                }
            }
        }
        for j in newOutputs.indices {
            if !newOutputs[j].deviceUID.isEmpty {
                newOutputs[j].deviceID = devices.device(withUID: newOutputs[j].deviceUID)?.id ?? 0
            } else if newOutputs[j].deviceID != 0 {
                if let d = devices.device(withID: newOutputs[j].deviceID) {
                    newOutputs[j].deviceUID = d.uid
                } else {
                    newOutputs[j].deviceID = 0
                }
            }
        }
        // Only publish (and persist) when something actually changed, so a
        // hot-plug re-resolve cannot loop through objectWillChange.
        if newInputs != inputs || newOutputs != outputs {
            inputs = newInputs
            outputs = newOutputs
            persist()
        }
    }
}

extension InputChannel: Codable {
    enum CodingKeys: String, CodingKey {
        case id, deviceID, deviceUID, channelL, channelR, level, gainDB, bus
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        deviceID = try c.decode(AudioDeviceID.self, forKey: .deviceID)
        // Settings written before UIDs existed have no deviceUID key.
        deviceUID = try c.decodeIfPresent(String.self, forKey: .deviceUID) ?? ""
        channelL = try c.decode(Int.self, forKey: .channelL)
        channelR = try c.decode(Int.self, forKey: .channelR)
        level = try c.decode(Double.self, forKey: .level)
        gainDB = try c.decode(Double.self, forKey: .gainDB)
        bus = try c.decode(Set<BusID>.self, forKey: .bus)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(deviceID, forKey: .deviceID)
        try c.encode(deviceUID, forKey: .deviceUID)
        try c.encode(channelL, forKey: .channelL)
        try c.encode(channelR, forKey: .channelR)
        try c.encode(level, forKey: .level)
        try c.encode(gainDB, forKey: .gainDB)
        try c.encode(bus, forKey: .bus)
    }
}

extension OutputChannel: Codable {
    enum CodingKeys: String, CodingKey { case id, deviceID, deviceUID, level }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        deviceID = try c.decode(AudioDeviceID.self, forKey: .deviceID)
        deviceUID = try c.decodeIfPresent(String.self, forKey: .deviceUID) ?? ""
        level = try c.decode(Double.self, forKey: .level)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(deviceID, forKey: .deviceID)
        try c.encode(deviceUID, forKey: .deviceUID)
        try c.encode(level, forKey: .level)
    }
}

extension BusID: Codable {}
