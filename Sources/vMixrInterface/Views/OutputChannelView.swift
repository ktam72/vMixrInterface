import SwiftUI
import CoreAudio
import AudioKit

// REQ-016..020: one output channel's controls (device, level, meters, device
// volume indicator + step buttons). Live-applies model changes to the engine.
@MainActor
struct OutputChannelView: View {
    @ObservedObject var mixer: MixerModel
    @ObservedObject var deviceManager: DeviceManager
    @ObservedObject var controller: AudioController
    let index: Int
    let meterL: Double
    let meterR: Double
    let peakL: Double
    let peakR: Double
    // CR-012: cached by MixerView.pollMeters (REQ-019) so the body does not
    // query Core Audio on every render.
    let volume: Double
    let volumeSupported: Bool

    var body: some View {
        let output = mixer.outputs[index]
        let levelBinding = Binding<Double>(
            get: { GainStep.levelToDB(mixer.outputs[index].level) },
            set: { mixer.outputs[index].level = GainStep.dbToLevel($0); applyAfterChange() }
        )
        let deviceVolume = volume
        let supportsVolume = volumeSupported
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(outputName(index)).font(.subheadline.bold())
                    .frame(width: InputChannelView.labelWidth, alignment: .leading)
                DevicePopupView(
                    uids: [""] + deviceManager.outputDevices.map(\.uid),
                    names: ["N/A"] + deviceManager.outputDevices.map(\.name),
                    selectedUID: output.deviceUID
                ) { setDevice($0) }
                .frame(width: InputChannelView.deviceButtonWidth, height: 19)
            }
            HStack(spacing: 4) {
                Text("レベル").font(.caption)
                    .frame(width: InputChannelView.labelWidth, alignment: .leading)
                Slider(value: levelBinding, in: GainStep.minDB...GainStep.maxDB)
                Text(levelDBText(output.level))
                    .font(.caption).monospacedDigit().frame(width: InputChannelView.valueWidth, alignment: .trailing)
            }
            meterRow("L", meterL, peakL)
            meterRow("R", meterR, peakR)
            HStack(spacing: 4) {
                Text("音量").font(.caption)
                    .frame(width: InputChannelView.labelWidth, alignment: .leading)
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.black.opacity(0.45))
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                            )
                        LinearGradient(
                            colors: [
                                Color(red: 0x18 / 255.0, green: 0xA8 / 255.0, blue: 0xBC / 255.0),
                                Color(red: 0x33 / 255.0, green: 0xD6 / 255.0, blue: 0xE8 / 255.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .mask(alignment: .leading) { Rectangle().frame(width: w * deviceVolume) }
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        if deviceVolume > 0.005 {
                            Rectangle()
                                .fill(Color.white.opacity(0.9))
                                .frame(width: 1, height: 6)
                                .offset(x: min(w - 1, max(0, w * deviceVolume - 0.5)))
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0).onChanged { g in
                            guard supportsVolume else { return }
                            let v = min(1, max(0, g.location.x / max(w, 1)))
                            _ = DeviceVolume.set(output.deviceID, Float(v))
                        }
                    )
                }
                .frame(maxWidth: .infinity)
                .frame(height: 6)
                .padding(.vertical, 4)
                Text(String(format: "%.0f%%", deviceVolume * 100))
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: InputChannelView.valueWidth, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func meterRow(_ label: String, _ value: Double, _ peak: Double) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
                .frame(width: InputChannelView.labelWidth, alignment: .leading)
            LevelMeterView(value: value, peak: peak)
                .frame(maxWidth: .infinity)
        }
    }

    private func outputName(_ index: Int) -> String {
        (BusID(rawValue: index) ?? .main).displayName
    }

    private func deviceName(uid: String) -> String {
        if uid.isEmpty { return "N/A" }
        return deviceManager.outputDevices.first { $0.uid == uid }?.name ?? "N/A"
    }

    private func setDevice(_ uid: String) {
        mixer.outputs[index].deviceUID = uid
        mixer.outputs[index].deviceID = deviceManager.device(withUID: uid)?.id ?? 0
        applyAfterChange()
    }

    private func applyAfterChange() {
        mixer.persist()
        controller.apply(model: mixer, devices: deviceManager)
    }

    // REQ-017: level slider readout; 0 -> -inf, 1 -> 0dB
    private func levelDBText(_ level: Double) -> String {
        if level <= 0.0001 { return "-∞" }
        let db = (20 * log10(level)).rounded()
        return db == 0 ? "0" : String(format: "%+.0f", db)
    }
}
