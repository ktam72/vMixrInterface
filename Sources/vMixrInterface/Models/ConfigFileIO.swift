import Foundation
import CoreAudio
import Combine

// REQ-037: read/write the standalone settings plist (custom schema, original-app-incompatible).
// Schema (see Design.md):
//   version / sampleRate / sampleFrameLength / streamerCount
//   input.N.{deviceID(-1=N/A), channelL, channelR, level, gainDB, bus.{main,aux1,aux2,aux3}}
//   output.N.{deviceID(-1=N/A), level}
//   streamer.N.*  (Phase 3)
@MainActor
final class ConfigFileIO: ObservableObject {
    @Published var lastPath: URL?

    private let mixer: MixerModel
    private let settings: AppSettings

    init(mixer: MixerModel, settings: AppSettings) {
        self.mixer = mixer
        self.settings = settings
    }

    // REQ-037: write the current model + settings to the given plist URL.
    func save(to url: URL) -> Bool {
        let dict = dictionary()
        do {
            try (dict as NSDictionary).write(to: url, atomically: true)
            lastPath = url
            return true
        } catch {
            NSLog("vMixrInterface: failed to save settings to \(url.path): \(error)")
            return false
        }
    }

    // REQ-037: read a settings plist and apply it to the model + settings.
    func load(from url: URL) -> Bool {
        guard let dict = NSDictionary(contentsOf: url) as? [String: Any] else {
            NSLog("vMixrInterface: failed to read settings from \(url.path)")
            return false
        }
        apply(dict)
        lastPath = url
        return true
    }

    // REQ-037: build the dictionary from the current model + settings.
    private func dictionary() -> [String: Any] {
        var d: [String: Any] = [
            "version": 1,
            "sampleRate": settings.sampleRate,
            "sampleFrameLength": settings.sampleFrameLength,
            "streamerCount": settings.streamerCount
        ]
        for i in 0..<MixerModel.inputCount {
            let inCh = mixer.input(i)
            d["input.\(i).deviceID"] = inCh.deviceID == 0 ? -1 : Int(inCh.deviceID)
            d["input.\(i).channelL"] = inCh.channelL
            d["input.\(i).channelR"] = inCh.channelR
            d["input.\(i).level"] = inCh.level
            d["input.\(i).gainDB"] = inCh.gainDB
            d["input.\(i).bus.main"] = inCh.bus.contains(.main)
            d["input.\(i).bus.aux1"] = inCh.bus.contains(.aux1)
            d["input.\(i).bus.aux2"] = inCh.bus.contains(.aux2)
            d["input.\(i).bus.aux3"] = inCh.bus.contains(.aux3)
        }
        for j in 0..<MixerModel.outputCount {
            let out = mixer.output(j)
            d["output.\(j).deviceID"] = out.deviceID == 0 ? -1 : Int(out.deviceID)
            d["output.\(j).level"] = out.level
        }
        return d
    }

    // REQ-037: apply a dictionary to the model + settings.
    private func apply(_ d: [String: Any]) {
        settings.sampleRate = d["sampleRate"] as? Double ?? 44100
        settings.sampleFrameLength = d["sampleFrameLength"] as? Int ?? 256
        settings.streamerCount = min(max(d["streamerCount"] as? Int ?? 8, 0), AppSettings.streamerCountRange.upperBound)
        for i in 0..<MixerModel.inputCount {
            let p = "input.\(i)"
            var inCh = mixer.input(i)
            inCh.deviceID = Self.deviceID(from: d["\(p).deviceID"] as? Int)
            inCh.channelL = d["\(p).channelL"] as? Int ?? 0
            inCh.channelR = d["\(p).channelR"] as? Int ?? 0
            inCh.level = min(max(d["\(p).level"] as? Double ?? 1.0, 0), GainStep.maxLevelLinear)
            inCh.gainDB = 0
            var bus: Set<BusID> = []
            if (d["\(p).bus.main"] as? Bool) == true { bus.insert(.main) }
            if (d["\(p).bus.aux1"] as? Bool) == true { bus.insert(.aux1) }
            if (d["\(p).bus.aux2"] as? Bool) == true { bus.insert(.aux2) }
            if (d["\(p).bus.aux3"] as? Bool) == true { bus.insert(.aux3) }
            inCh.bus = bus
            mixer.inputs[i] = inCh
        }
        for j in 0..<MixerModel.outputCount {
            let p = "output.\(j)"
            var out = mixer.output(j)
            out.deviceID = Self.deviceID(from: d["\(p).deviceID"] as? Int)
            out.level = min(max(d["\(p).level"] as? Double ?? 1.0, 0), GainStep.maxLevelLinear)
            mixer.outputs[j] = out
        }
        mixer.persist()
    }

    // REQ-037: map a stored deviceID (-1 = N/A) to the runtime AudioDeviceID (0 = N/A).
    private static func deviceID(from raw: Int?) -> AudioDeviceID {
        guard let raw, raw >= 0 else { return 0 }
        return AudioDeviceID(raw)
    }
}
