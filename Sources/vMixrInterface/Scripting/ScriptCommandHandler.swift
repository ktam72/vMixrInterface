import Foundation
import AppKit
import Carbon

// REQ-038/039: AppleScript event codes (must match the sdef).
enum ScriptCodes {
    static let suite: FourCharCode = Self.four("vmix")
    static let openID: FourCharCode = Self.four("vopen")
    static let connectID: FourCharCode = Self.four("cnct")
    static let disconnectID: FourCharCode = Self.four("dscn")
    static let songPropertyID: FourCharCode = Self.four("mtsg")

    static func four(_ s: String) -> FourCharCode {
        s.utf8.prefix(4).reduce(FourCharCode(0)) { (acc, byte) in (acc << 8) | FourCharCode(byte) }
    }
}

// REQ-038/039: registers Apple event handlers for the app's script terms
// (open / connect / disconnect / metadata song) and dispatches them to the model.
// Apple events are delivered on the main thread, so the whole handler is @MainActor.
@MainActor
final class ScriptCommandHandler: NSObject {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        super.init()
        install()
    }

    // Register one handler per script term (the same selector dispatches by event ID).
    private func install() {
        let manager = NSAppleEventManager.shared()
        let selector = #selector(handleAppleEvent(_:withReplyEvent:))
        manager.setEventHandler(self, andSelector: selector, forEventClass: kCoreEventClass, andEventID: kAEGetData)
        manager.setEventHandler(self, andSelector: selector, forEventClass: kCoreEventClass, andEventID: kAESetData)
        manager.setEventHandler(self, andSelector: selector, forEventClass: ScriptCodes.suite, andEventID: ScriptCodes.openID)
        manager.setEventHandler(self, andSelector: selector, forEventClass: ScriptCodes.suite, andEventID: ScriptCodes.connectID)
        manager.setEventHandler(self, andSelector: selector, forEventClass: ScriptCodes.suite, andEventID: ScriptCodes.disconnectID)
    }

    // REQ-038: the @objc entry point invoked by the Apple Event Manager (main thread).
    @objc
    func handleAppleEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        switch (event.eventClass, event.eventID) {
        case (ScriptCodes.suite, ScriptCodes.openID):
            handleOpen(event)
        case (kCoreEventClass, kAEGetData):
            if let direct = event.forKeyword(keyDirectObject), containsCharCode(direct, ScriptCodes.songPropertyID) {
                reply.setDescriptor(NSAppleEventDescriptor(string: model.metadataSong), forKeyword: keyDirectObject)
            }
        case (kCoreEventClass, kAESetData):
            if let direct = event.forKeyword(keyDirectObject), containsCharCode(direct, ScriptCodes.songPropertyID) {
                if let value = findString(event) { model.metadataSong = value }
            }
        case (ScriptCodes.suite, ScriptCodes.connectID):
            _ = model.connectStreamer(index: event.forKeyword(keyDirectObject)?.int32Value ?? 0)
        case (ScriptCodes.suite, ScriptCodes.disconnectID):
            _ = model.disconnectStreamer(index: event.forKeyword(keyDirectObject)?.int32Value ?? 0)
        default:
            break
        }
    }

    // REQ-038: load the settings file passed to the「open」event.
    private func handleOpen(_ event: NSAppleEventDescriptor) {
        let direct = event.forKeyword(keyDirectObject)
        let url = direct.flatMap(fileURL(from:)) ?? findFileURL(event)
        guard let url else {
            NSLog("vMixrInterface: unable to load the specified settings file")
            return
        }
        model.openConfig(from: url)
    }

    // REQ-038: accept a 'furl' descriptor or a path string.
    private func fileURL(from descriptor: NSAppleEventDescriptor) -> URL? {
        if descriptor.descriptorType == typeFileURL { return descriptor.fileURLValue }
        guard let text = descriptor.stringValue else { return nil }
        if text.hasPrefix("/") { return URL(fileURLWithPath: text) }
        let home = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(text)
        return FileManager.default.fileExists(atPath: home.path) ? home : nil
    }

    private func findFileURL(_ d: NSAppleEventDescriptor) -> URL? {
        if d.descriptorType == typeFileURL { return d.fileURLValue }
        for i in 1...d.numberOfItems {
            if let item = d.atIndex(i), let url = findFileURL(item) { return url }
        }
        return nil
    }

    // REQ-038: whether a descriptor (recursively) references the metadata-song property.
    private func containsCharCode(_ descriptor: NSAppleEventDescriptor, _ code: FourCharCode) -> Bool {
        if descriptor.descriptorType == typeChar && descriptor.enumCodeValue == code { return true }
        for i in 1...descriptor.numberOfItems {
            if let sub = descriptor.atIndex(i), containsCharCode(sub, code) { return true }
        }
        return false
    }

    private func findString(_ d: NSAppleEventDescriptor) -> String? {
        if d.descriptorType == typeUnicodeText { return d.stringValue }
        for i in 1...d.numberOfItems {
            if let item = d.atIndex(i), let value = findString(item) { return value }
        }
        return nil
    }
}
