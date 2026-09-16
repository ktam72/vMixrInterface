import AppKit

// REQ-038/039: the AppKit app delegate. Creates the shared model and installs the
// AppleScript event handlers (the handler registers itself with NSAppleEventManager).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var scriptHandler: ScriptCommandHandler?

    func applicationDidFinishLaunching(_ notification: Notification) {
        scriptHandler = ScriptCommandHandler(model: AppModel.make())
    }
}
