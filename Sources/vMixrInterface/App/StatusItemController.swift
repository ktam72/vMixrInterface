import AppKit
import Combine
import CoreAudio
import AudioKit

// REQ-030/031: the menu-bar status item (「vM」monogram icon) and its menu:
// 4 rows of「output device name + device volume slider + speaker icon」,
// then「vMixrInterface」and「vMixrInterface を終了」.
@MainActor
final class StatusItemController {
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    private var appliedOutputDevices: [AudioDeviceID] = []

    // REQ-030: create the status item with the 「vM」monogram icon and build the menu.
    func configure(mixer: MixerModel, deviceManager: DeviceManager) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.monogramImage()
        statusItem = item
        rebuildMenu(mixer: mixer, devices: deviceManager)
    }

    // REQ-030: render the 「vM」monogram (15pt bold, tight kern) as a template image
    // so the menu bar auto-inverts it for light/dark appearance.
    private static func monogramImage() -> NSImage? {
        let font = NSFont.systemFont(ofSize: 15, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .kern: -0.5]
        let text = NSAttributedString(string: "vM", attributes: attrs)
        let size = text.size()
        let image = NSImage(size: NSSize(width: ceil(size.width), height: ceil(size.height)))
        image.lockFocus()
        text.draw(at: .zero)
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    // REQ-031: rebuild the menu when the mixer's output device selection changes.
    func observe(mixer: MixerModel, deviceManager: DeviceManager) {
        cancellables.removeAll()
        mixer.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let devices = deviceManager.devices.map { $0.id }
                if devices != self.appliedOutputDevices {
                    self.rebuildMenu(mixer: mixer, devices: deviceManager)
                    self.appliedOutputDevices = devices
                }
            }
        }.store(in: &cancellables)
    }

    // REQ-031: build the menu (4 volume rows + vMixrInterface + quit).
    private func rebuildMenu(mixer: MixerModel, devices: DeviceManager) {
        let menu = NSMenu()
        for j in 0..<MixerModel.outputCount {
            let output = mixer.output(j)
            let device = output.deviceID == 0 ? nil : devices.device(withID: output.deviceID)
            let title = device?.name ?? "N/A"
            let initial = device.map { Double(DeviceVolume.get($0.id) ?? 1.0) } ?? 0
            let supportsVolume = device.map { DeviceVolume.get($0.id) != nil } ?? false
            let row = StatusVolumeRow(title: title, initialVolume: initial, enabled: supportsVolume) { value in
                if let device { _ = DeviceVolume.set(device.id, Float(value)) }
            }
            let item = NSMenuItem()
            item.view = row
            menu.addItem(item)
        }
        let mixerItem = NSMenuItem(title: "vMixrInterface", action: #selector(openMixer), keyEquivalent: "")
        mixerItem.target = self
        menu.addItem(mixerItem)
        let quitItem = NSMenuItem(title: "vMixrInterface を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        statusItem?.menu = menu
    }

    @objc private func openMixer() {
        NSApp.activate(ignoringOtherApps: true)
        AppModel.shared?.openMixerWindow()
    }
}

// REQ-031: a single menu row = device name label + volume slider + speaker icon.
@MainActor
final class StatusVolumeRow: NSView {
    private let onChange: (Double) -> Void
    private let label: NSTextField
    private let slider: NSSlider
    private let icon: NSImageView

    init(title: String, initialVolume: Double, enabled: Bool, onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        self.label = NSTextField(labelWithString: title)
        self.icon = NSImageView()
        self.slider = NSSlider(value: initialVolume, minValue: 0, maxValue: 1, target: nil, action: nil)
        super.init(frame: .zero)
        self.icon.image = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil)
        self.slider.target = self
        self.slider.action = #selector(sliderChanged)
        self.slider.isEnabled = enabled

        label.preferredMaxLayoutWidth = 150
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 12)

        let stack = NSStackView(views: [label, slider, icon])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            label.widthAnchor.constraint(equalToConstant: 150),
            slider.widthAnchor.constraint(equalToConstant: 100)
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    @objc private func sliderChanged() {
        onChange(Double(slider.doubleValue))
    }
}
