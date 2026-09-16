import SwiftUI
import AppKit

// REQ-007: the application menu composition (main / file / streamer / window / help).
@MainActor
struct AppCommands: Commands {
    let appModel: AppModel

    var body: some Commands {
        // REQ-007: ファイル menu（開く... / 保存 / 別名で保存...）
        CommandGroup(replacing: .saveItem) {
            Button("開く...") { appModel.openConfig() }
                .keyboardShortcut("o", modifiers: .command)
            Divider()
            Button("保存") { appModel.saveConfig() }
                .keyboardShortcut("s", modifiers: .command)
            Button("別名で保存...") { appModel.saveConfigAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
        }

        // REQ-007: 設定…（Cmd+,）opens the「環境設定」window
        CommandGroup(replacing: .appSettings) {
            Button("設定…") { appModel.openPreferencesWindow() }
                .keyboardShortcut(",", modifiers: .command)
        }

        // REQ-007/041: ストリーマー menu（placeholder items; real windows in Phase 3）
        CommandMenu("ストリーマー") {
            ForEach(0..<appModel.streamerCount, id: \.self) { i in
                Button("ストリーマー \(i + 1)") { }
            }
        }

        // REQ-007: ウインドウ menu streamer items（after the auto window list）
        CommandGroup(after: .windowList) {
            ForEach(0..<appModel.streamerCount, id: \.self) { i in
                Button("ストリーマー \(i + 1)") { }
            }
        }

        // REQ-007: ヘルプ menu
        CommandGroup(replacing: .help) {
            Button("vMixrInterface ヘルプ") { }
            Button("ReadMe") { }
            Button("ChangeLog") { }
        }
    }
}
