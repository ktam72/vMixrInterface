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
                        peakL: outputPeaksL[i], peakR: outputPeaksR[i]
                    )
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onReceive(meterTimer) { _ in pollMeters() }
    }

    // Poll the engine's raw per-channel peaks and hold the peak with a ~500ms decay.
    private func pollMeters() {
        // 60fps per-tick decays (recomputed from the 10fps values 0.85 / 0.985 so
        // the visual falloff rate is unchanged).
        let decay = 0.9733
        let peakDecay = 0.9975
        let peaks = controller.engine.peaksSnapshot()
        for i in 0..<MixerModel.inputCount {
            inputMetersL[i] = max(Double(peaks.inputL[i]), inputMetersL[i] * decay)
            inputMetersR[i] = max(Double(peaks.inputR[i]), inputMetersR[i] * decay)
            inputPeaksL[i] = max(Double(peaks.inputL[i]), inputPeaksL[i] * peakDecay)
            inputPeaksR[i] = max(Double(peaks.inputR[i]), inputPeaksR[i] * peakDecay)
        }
        for j in 0..<MixerModel.outputCount {
            outputMetersL[j] = max(Double(peaks.outputL[j]), outputMetersL[j] * decay)
            outputMetersR[j] = max(Double(peaks.outputR[j]), outputMetersR[j] * decay)
            outputPeaksL[j] = max(Double(peaks.outputL[j]), outputPeaksL[j] * peakDecay)
            outputPeaksR[j] = max(Double(peaks.outputR[j]), outputPeaksR[j] * peakDecay)
        }
    }
}
