import SwiftUI
import Combine
import AudioKit

// REQ-010..020: the mixer window. Left column = 4 input channels, right column =
// メイン + 3 aux output channels. Polls the engine's per-channel peaks and applies
// peak hold (~500ms) for the level meters.
@MainActor
struct MixerView: View {
    @ObservedObject var deviceManager: DeviceManager
    @ObservedObject var settings: AppSettings
    @ObservedObject var mixer: MixerModel
    @ObservedObject var controller: AudioController

    @State private var inputMetersL = Array(repeating: 0.0, count: MixerModel.inputCount)
    @State private var inputMetersR = Array(repeating: 0.0, count: MixerModel.inputCount)
    @State private var outputMetersL = Array(repeating: 0.0, count: MixerModel.outputCount)
    @State private var outputMetersR = Array(repeating: 0.0, count: MixerModel.outputCount)
    // Slow-decay peak hold for the meter's trailing tick.
    @State private var inputPeaksL = Array(repeating: 0.0, count: MixerModel.inputCount)
    @State private var inputPeaksR = Array(repeating: 0.0, count: MixerModel.inputCount)
    @State private var outputPeaksL = Array(repeating: 0.0, count: MixerModel.outputCount)
    @State private var outputPeaksR = Array(repeating: 0.0, count: MixerModel.outputCount)
    // CR-012: device master volume cache, polled once per tick here so the
    // channel views can render it without querying Core Audio in their bodies.
    @State private var outputVolumes = Array(repeating: 1.0, count: MixerModel.outputCount)
    @State private var outputVolumeSupported = Array(repeating: false, count: MixerModel.outputCount)

    private let meterTimer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        // Each row pairs 入力N with the Nth output (メイン/Aux1/Aux2/Aux3) so the
        // left and right columns stay horizontally aligned and balanced.
        Grid(horizontalSpacing: 8, verticalSpacing: 6) {
            ForEach(0..<min(MixerModel.inputCount, MixerModel.outputCount), id: \.self) { i in
                GridRow {
                    InputChannelView(
                        mixer: mixer, deviceManager: deviceManager, controller: controller,
                        index: i, meterL: inputMetersL[i], meterR: inputMetersR[i],
                        peakL: inputPeaksL[i], peakR: inputPeaksR[i]
                    )
                    OutputChannelView(
                        mixer: mixer, deviceManager: deviceManager, controller: controller,
                        index: i, meterL: outputMetersL[i], meterR: outputMetersR[i],
                        peakL: outputPeaksL[i], peakR: outputPeaksR[i],
                        volume: outputVolumes[i], volumeSupported: outputVolumeSupported[i]
                    )
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onReceive(meterTimer) { _ in pollMeters() }
    }

    // Poll the engine's raw per-channel peaks and hold the peak with a ~500ms decay.
    // CR-012: only write @State when the value actually changed. SwiftUI
    // invalidates the whole view tree on every write (even equal values), which
    // forced a 60fps full-tree relayout while silent (~68% CPU measured).
    // 5e-7 corresponds to <0.1px on a ~600pt bar, so the frozen steady state is
    // visually identical to a continuous decay.
    private func pollMeters() {
        // 60fps per-tick decays (recomputed from the 10fps values 0.85 / 0.985 so
        // the visual falloff rate is unchanged).
        let decay = 0.9733
        let peakDecay = 0.9975
        let epsilon = 5e-7
        let peaks = controller.engine.peaksSnapshot()
        for i in 0..<MixerModel.inputCount {
            let l = max(Double(peaks.inputL[i]), inputMetersL[i] * decay)
            if abs(l - inputMetersL[i]) > epsilon { inputMetersL[i] = l }
            let r = max(Double(peaks.inputR[i]), inputMetersR[i] * decay)
            if abs(r - inputMetersR[i]) > epsilon { inputMetersR[i] = r }
            let pl = max(Double(peaks.inputL[i]), inputPeaksL[i] * peakDecay)
            if abs(pl - inputPeaksL[i]) > epsilon { inputPeaksL[i] = pl }
            let pr = max(Double(peaks.inputR[i]), inputPeaksR[i] * peakDecay)
            if abs(pr - inputPeaksR[i]) > epsilon { inputPeaksR[i] = pr }
        }
        for j in 0..<MixerModel.outputCount {
            let l = max(Double(peaks.outputL[j]), outputMetersL[j] * decay)
            if abs(l - outputMetersL[j]) > epsilon { outputMetersL[j] = l }
            let r = max(Double(peaks.outputR[j]), outputMetersR[j] * decay)
            if abs(r - outputMetersR[j]) > epsilon { outputMetersR[j] = r }
            let pl = max(Double(peaks.outputL[j]), outputPeaksL[j] * peakDecay)
            if abs(pl - outputPeaksL[j]) > epsilon { outputPeaksL[j] = pl }
            let pr = max(Double(peaks.outputR[j]), outputPeaksR[j] * peakDecay)
            if abs(pr - outputPeaksR[j]) > epsilon { outputPeaksR[j] = pr }
        }
        // REQ-019: refresh the cached device volumes. A step below 1e-6 is
        // subpixel; skipping that write keeps silent idle free of invalidations.
        for j in 0..<MixerModel.outputCount {
            let id = mixer.outputs[j].deviceID
            let raw = id != 0 ? DeviceVolume.get(id) : nil
            let volume = raw.map { Double($0) } ?? (id != 0 ? 1.0 : 0.0)
            if abs(volume - outputVolumes[j]) > 1e-6 { outputVolumes[j] = volume }
            let supported = raw != nil
            if outputVolumeSupported[j] != supported { outputVolumeSupported[j] = supported }
        }
    }
}
