import SwiftUI
import Combine

// REQ-032..035: preferences view model (wraps AppSettings)
@MainActor
final class PreferencesViewModel: ObservableObject {
    let settings: AppSettings
    init(settings: AppSettings) { self.settings = settings }
}

// REQ-032..036: the「環境設定」panel (400×170). Sample frame length / sample rate
// / streamer count, applied on relaunch (REQ-005).
@MainActor
struct PreferencesView: View {
    @ObservedObject var viewModel: PreferencesViewModel

    var body: some View {
        let s = viewModel.settings
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("サンプルフレーム長:")
                Picker("", selection: Binding(
                    get: { Double(s.sampleFrameLength) },
                    set: { s.sampleFrameLength = Int($0) }
                )) {
                    ForEach(AppSettings.frameLengthChoices.map { Double($0) }, id: \.self) {
                        Text("\(Int($0))").tag($0)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
            }
            HStack {
                Text("システムサンプルレート(Hz):")
                Picker("", selection: Binding(
                    get: { s.sampleRate },
                    set: { s.sampleRate = $0 }
                )) {
                    ForEach(AppSettings.sampleRateChoices, id: \.self) {
                        Text("\(Int($0))").tag($0)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
            }
            HStack {
                Text("ストリーマー数:")
                Stepper("", value: Binding(
                    get: { s.streamerCount },
                    set: { s.streamerCount = min(max($0, 0), AppSettings.streamerCountRange.upperBound) }
                ), in: AppSettings.streamerCountRange)
                .labelsHidden()
                Text("\(s.streamerCount)")
                    .monospacedDigit()
                    .frame(width: 24, alignment: .trailing)
            }
            // REQ-036: changes take effect after relaunch
            Text("変更は再起動後に有効になります")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(16)
        .frame(width: 400, height: 170)
    }
}
