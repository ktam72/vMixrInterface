import Foundation
import Combine
import CoreAudio
import AudioKit

// Coordinates MixerModel + DeviceManager + AudioEngine
@MainActor
public final class AudioController: ObservableObject {
    @Published public private(set) var isRunning = false
    public let engine = AudioEngine()

    private var appliedInputDevices: [AudioDeviceID] = []
    private var appliedOutputDevices: [AudioDeviceID] = []
    private var storedSettings: AppSettings?

    public init() {}

    // REQ-005/021/022: build engine config from the model and devices, then start.
    @discardableResult
    public func start(model: MixerModel, devices: DeviceManager, settings: AppSettings) -> Bool {
        storedSettings = settings
        let (inConfigs, outConfigs) = Self.buildConfigs(model: model, devices: devices)
        let ok = engine.start(
            sampleRate: settings.sampleRate,
            frameLength: settings.sampleFrameLength,
            inputChannels: inConfigs,
            outputChannels: outConfigs
        )
        appliedInputDevices = inConfigs.map { $0.deviceID }
        appliedOutputDevices = outConfigs.map { $0.deviceID }
        isRunning = ok
        return ok
    }

    // CR-005: the engine captures each device directly (one IOProc per device),
    // so there is no single system-default input to configure.

    // REQ-010..020: apply the current model to the running engine. Rebuilds the
    // units only when a channel's device changes; otherwise updates parameters
    // live so slider/gain/bus edits are glitch-free.
    public func apply(model: MixerModel, devices: DeviceManager) {
        let (inConfigs, outConfigs) = Self.buildConfigs(model: model, devices: devices)
        let inDevices = inConfigs.map { $0.deviceID }
        let outDevices = outConfigs.map { $0.deviceID }
        if inDevices != appliedInputDevices || outDevices != appliedOutputDevices, let s = storedSettings {
            _ = start(model: model, devices: devices, settings: s)
        } else {
            for i in 0..<AudioEngine.inputCount {
                engine.updateInput(
                    i,
                    active: inConfigs[i].deviceID != 0,
                    level: inConfigs[i].level,
                    gainDB: inConfigs[i].gainDB,
                    channelL: inConfigs[i].channelL,
                    channelR: inConfigs[i].channelR
                )
            }
            for j in 0..<AudioEngine.outputCount {
                engine.updateOutput(
                    j,
                    active: outConfigs[j].deviceID != 0,
                    level: outConfigs[j].level,
                    activeInputIndices: outConfigs[j].activeInputIndices
                )
            }
        }
    }

    public func stop() {
        engine.stop()
        appliedInputDevices = []
        appliedOutputDevices = []
        isRunning = false
    }

    private static func buildConfigs(model: MixerModel, devices: DeviceManager) -> ([InputChannelConfig], [OutputChannelConfig]) {
        let inputConfigs = (0..<MixerModel.inputCount).map { i -> InputChannelConfig in
            let input = model.input(i)
            let device = input.deviceID == 0 ? nil : devices.device(withID: input.deviceID)
            return InputChannelConfig(
                deviceID: input.deviceID,
                inputChannelCount: device?.inputChannels ?? 0,
                channelL: input.channelL,
                channelR: input.channelR,
                level: input.level,
                gainDB: input.gainDB
            )
        }
        let outputConfigs = (0..<MixerModel.outputCount).map { j -> OutputChannelConfig in
            let output = model.output(j)
            let bus = BusID(rawValue: j) ?? .main
            let active: Set<Int> = Set(model.inputs.filter { $0.bus.contains(bus) }.map { $0.id })
            return OutputChannelConfig(
                deviceID: output.deviceID,
                level: output.level,
                activeInputIndices: active
            )
        }
        return (inputConfigs, outputConfigs)
    }
}
