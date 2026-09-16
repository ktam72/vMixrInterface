import Combine
import AppKit
import AudioKit
import UniformTypeIdentifiers

// REQ-007/030/031/032/037: shared application model. Bridges the SwiftUI scene
// graph and the AppKit AppDelegate (statusItem + AppleScript). Owns the core models
// and forwards their changes so the menu and status item stay in sync.
@MainActor
final class AppModel: ObservableObject {
    static var shared: AppModel?

    let deviceManager = DeviceManager()
    let settings = AppSettings()
    let mixer = MixerModel()
    let controller = AudioController()
    let statusItem = StatusItemController()
    let configIO: ConfigFileIO
    let preferences: PreferencesViewModel

    // REQ-007/036: streamer count captured at launch (changes take effect on relaunch).
    let streamerCount: Int

    // REQ-031: closures set by the SwiftUI layer to open the windows from AppKit.
    var openMixerWindow: @MainActor () -> Void = { }
    var openPreferencesWindow: @MainActor () -> Void = { }

    // REQ-038: metadata song (reflected in all streamers; applied in Phase 3).
    @Published var metadataSong = ""

    private var cancellables = Set<AnyCancellable>()

    private init() {
        configIO = ConfigFileIO(mixer: mixer, settings: settings)
        preferences = PreferencesViewModel(settings: settings)
        streamerCount = settings.streamerCount
        let publishers: [AnyPublisher<Void, Never>] = [
            AnyPublisher(deviceManager.objectWillChange),
            AnyPublisher(settings.objectWillChange),
            AnyPublisher(mixer.objectWillChange),
            AnyPublisher(controller.objectWillChange)
        ]
        publishers.forEach { publisher in
            publisher.sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.objectWillChange.send() }
            }.store(in: &cancellables)
        }
        AppModel.shared = self
    }

    static func make() -> AppModel {
        if let shared { return shared }
        return AppModel()
    }

    // REQ-005/006: start the engine and install the hot-plug listener on launch.
    func start() {
        deviceManager.installHotPlugListener()
        // REQ-004: resolve persisted device UIDs to the current IDs before the
        // engine starts (IDs change when coreaudiod restarts).
        mixer.resolveDevices(deviceManager)
        // REQ-006: on hot-plug, re-resolve UIDs and re-apply the configuration.
        deviceManager.onDevicesChanged = { [weak self] in
            guard let self else { return }
            self.mixer.resolveDevices(self.deviceManager)
            self.controller.apply(model: self.mixer, devices: self.deviceManager)
        }
        _ = controller.start(model: mixer, devices: deviceManager, settings: settings)
        statusItem.configure(mixer: mixer, deviceManager: deviceManager)
        statusItem.observe(mixer: mixer, deviceManager: deviceManager)
    }

    // REQ-010..023: apply the current mixer state to the engine.
    func applyAll() {
        controller.apply(model: mixer, devices: deviceManager)
    }

    // REQ-037: open a settings plist (file menu「開く...」).
    func openConfig() -> Bool {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return openConfig(from: url)
    }

    // REQ-037: save the current state (file menu「保存」); falls back to save-as.
    func saveConfig() -> Bool {
        if let url = configIO.lastPath { return configIO.save(to: url) }
        return saveConfigAs()
    }

    // REQ-037: save the current state to a chosen URL (file menu「別名で保存...」).
    func saveConfigAs() -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "vMixrInterface"
        panel.allowedContentTypes = [.propertyList]
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return configIO.save(to: url)
    }

    // REQ-038: load a settings file by URL (AppleScript「open」) and apply it.
    func openConfig(from url: URL) -> Bool {
        let ok = configIO.load(from: url)
        if ok { applyAll() }
        return ok
    }

    // REQ-038: connect the given streamer (AppleScript「connect」).
    // TODO(Phase 3): actually start streaming; currently validates the index only.
    func connectStreamer(index: Int32) -> Bool {
        let valid = index >= 0 && index < Int32(streamerCount)
        NSLog("vMixrInterface: connect streamer \(index + 1) (Phase 3, valid=\(valid))")
        return valid
    }

    // REQ-038: disconnect the given streamer (AppleScript「disconnect」).
    // TODO(Phase 3): actually stop streaming; currently validates the index only.
    func disconnectStreamer(index: Int32) -> Bool {
        let valid = index >= 0 && index < Int32(streamerCount)
        NSLog("vMixrInterface: disconnect streamer \(index + 1) (Phase 3, valid=\(valid))")
        return valid
    }
}
