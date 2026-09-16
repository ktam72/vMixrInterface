import SwiftUI
import AudioKit

// REQ-001..003: app entry. The mixer window (vMixrInterface, 629×521) + the「環境設定」window.
@main
struct vMixrInterfaceApp: App {
    @StateObject private var appModel = AppModel.make()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("vMixrInterface", id: "mixer") {
            MixerWindowContent(appModel: appModel)
        }
        .defaultSize(width: 629, height: 517)
        .windowResizability(.contentSize)
        .commands {
            AppCommands(appModel: appModel)
        }

        // REQ-032: the「環境設定」window (400×170), opened via「設定…」（Cmd+,）
        Window("環境設定", id: "preferences") {
            PreferencesView(viewModel: appModel.preferences)
        }
        .defaultSize(width: 400, height: 170)
        .windowResizability(.contentSize)
    }
}

// The mixer window content; wires the shared model's window-opening closures.
@MainActor
private struct MixerWindowContent: View {
    let appModel: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MixerView(
            deviceManager: appModel.deviceManager,
            settings: appModel.settings,
            mixer: appModel.mixer,
            controller: appModel.controller
        )
        .frame(width: 629, height: 517)
        .onAppear {
            appModel.start()
            appModel.openMixerWindow = { openWindow(id: "mixer") }
            appModel.openPreferencesWindow = { openWindow(id: "preferences") }
        }
    }
}
