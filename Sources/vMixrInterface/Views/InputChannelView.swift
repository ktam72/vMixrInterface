import SwiftUI
import CoreAudio
import AudioKit
import AppKit

// REQ-010..015: one input channel's controls (device, level, meters, bus
// routing). Live-applies changes to the engine via AudioController.
@MainActor
struct InputChannelView: View {
    @ObservedObject var mixer: MixerModel
    @ObservedObject var deviceManager: DeviceManager
    @ObservedObject var controller: AudioController
    let index: Int
    let meterL: Double
    let meterR: Double
    let peakL: Double
    let peakR: Double

    var body: some View {
        let input = mixer.inputs[index]
        let levelBinding = Binding<Double>(
            get: { GainStep.levelToDB(mixer.inputs[index].level) },
            set: { mixer.inputs[index].level = GainStep.dbToLevel($0); applyAfterChange() }
        )
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("入力 \(index + 1)").font(.subheadline.bold())
                    .frame(width: Self.labelWidth, alignment: .leading)
                DevicePopupView(
                    uids: [""] + deviceManager.inputDevices.map(\.uid),
                    names: ["N/A"] + deviceManager.inputDevices.map(\.name),
                    selectedUID: input.deviceUID
                ) { setDevice($0) }
                .frame(width: Self.deviceButtonWidth, height: 19)
            }
            HStack(spacing: 4) {
                Text("レベル").font(.caption)
                    .frame(width: Self.labelWidth, alignment: .leading)
                Slider(value: levelBinding, in: GainStep.minDB...GainStep.maxDB)
                Text(levelDBText(input.level))
                    .font(.caption).monospacedDigit().frame(width: Self.valueWidth, alignment: .trailing)
            }
            meterRow("L", meterL, peakL)
            meterRow("R", meterR, peakR)
            HStack(spacing: 4) {
                Color.clear.frame(width: Self.labelWidth, height: 0)
                ForEach(BusID.allCases, id: \.self) { bus in
                    let selected = input.bus.contains(bus)
                    Button { toggleBus(bus) } label: {
                        Text(bus.displayName)
                            .font(.caption2)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 2)
                            .background(selected ? Color.red : Color(nsColor: .quaternaryLabelColor))
                            .foregroundColor(selected ? .white : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // Shared column metrics so every control row aligns to the same left/right
    // edge within a card.
    static let labelWidth: CGFloat = 52
    static let valueWidth: CGFloat = 40
    // Device dropdown width. The SwiftUI Menu control caps its label layout
    // area (~111pt) and truncates long device names, so the dropdown is an
    // AppKit NSPopUpButton which sizes itself to the title.
    static let deviceButtonWidth: CGFloat = 200

    private func meterRow(_ label: String, _ value: Double, _ peak: Double) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
                .frame(width: Self.labelWidth, alignment: .leading)
            LevelMeterView(value: value, peak: peak)
                .frame(maxWidth: .infinity)
        }
    }

    private func deviceName(uid: String) -> String {
        if uid.isEmpty { return "N/A" }
        return deviceManager.inputDevices.first { $0.uid == uid }?.name ?? "N/A"
    }

    private func setDevice(_ uid: String) {
        mixer.inputs[index].deviceUID = uid
        mixer.inputs[index].deviceID = deviceManager.device(withUID: uid)?.id ?? 0
        applyAfterChange()
    }

    private func applyAfterChange() {
        mixer.persist()
        controller.apply(model: mixer, devices: deviceManager)
    }

    private func toggleBus(_ bus: BusID) {
        if mixer.inputs[index].bus.contains(bus) {
            mixer.inputs[index].bus.remove(bus)
        } else {
            mixer.inputs[index].bus.insert(bus)
        }
        applyAfterChange()
    }

    // REQ-012: level slider readout; 0 -> -inf, max -> +maxDB
    private func levelDBText(_ level: Double) -> String {
        if level <= 0.0001 { return "-∞" }
        let db = (20 * log10(level)).rounded()
        return db == 0 ? "0" : String(format: "%+.0f", db)
    }
}

// Device dropdown backed by an AppKit NSPopUpButton: unlike the SwiftUI Menu
// (which caps the label layout area and truncates long names), a popup button
// shows the full title and sizes its menu to the longest item.
struct DevicePopupView: NSViewRepresentable {
    let uids: [String]
    let names: [String]
    let selectedUID: String
    let onSelect: (String) -> Void

    // Fills the proposed SwiftUI frame exactly instead of resisting with its
    // own intrinsic size (which would truncate the title).
    final class FittingPopUpButton: NSPopUpButton {
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context: Context) -> FittingPopUpButton {
        let button = FittingPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .small
        button.target = context.coordinator
        button.action = #selector(Coordinator.selected)
        return button
    }

    func updateNSView(_ button: FittingPopUpButton, context: Context) {
        context.coordinator.onSelect = onSelect
        let itemsChanged = context.coordinator.uids != uids || context.coordinator.names != names
        if itemsChanged {
            context.coordinator.uids = uids
            context.coordinator.names = names
            button.removeAllItems()
            for name in names { button.addItem(withTitle: name) }
        }
        if itemsChanged || context.coordinator.selectedUID != selectedUID {
            context.coordinator.selectedUID = selectedUID
            if let idx = uids.firstIndex(of: selectedUID) {
                button.selectItem(at: idx)
            }
        }
    }

    final class Coordinator: NSObject {
        var uids: [String] = []
        var names: [String] = []
        var selectedUID: String?
        var onSelect: (String) -> Void
        init(onSelect: @escaping (String) -> Void) { self.onSelect = onSelect }
        @objc func selected(_ sender: NSPopUpButton) {
            let idx = sender.indexOfSelectedItem
            guard idx >= 0, idx < uids.count else { return }
            onSelect(uids[idx])
        }
    }
}
