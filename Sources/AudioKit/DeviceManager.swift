import Foundation
import CoreAudio

// REQ-006: device list / name / hot-plug / device volume management
public struct AudioDeviceInfo: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    // Stable identifier: AudioObjectIDs are volatile (they change when
    // coreaudiod restarts), so settings are persisted and resolved by UID.
    public var uid: String
    public var name: String
    public var inputChannels: Int
    public var outputChannels: Int
    public var isInput: Bool { inputChannels > 0 }
    public var isOutput: Bool { outputChannels > 0 }
}

// REQ-006: enumerate, name, hot-plug devices via Core Audio.
@MainActor
public final class DeviceManager: ObservableObject {
    @Published public private(set) var devices: [AudioDeviceInfo] = []
    @Published public private(set) var inputDevices: [AudioDeviceInfo] = []
    @Published public private(set) var outputDevices: [AudioDeviceInfo] = []

    private var listenerInstalled = false
    // REQ-006: invoked after the device list is refreshed (hot-plug) so the app
    // can re-resolve channel UIDs and re-apply the engine configuration.
    public var onDevicesChanged: (() -> Void)?

    public init() {
        refresh()
    }

    public func refresh() {
        let list = Self.deviceList().map { id in
            AudioDeviceInfo(
                id: id,
                uid: Self.deviceUID(id),
                name: Self.deviceName(id),
                inputChannels: Self.channelCount(id, scope: kAudioObjectPropertyScopeInput),
                outputChannels: Self.channelCount(id, scope: kAudioObjectPropertyScopeOutput)
            )
        }
        devices = list
        inputDevices = list.filter { $0.isInput }
        outputDevices = list.filter { $0.isOutput }
        onDevicesChanged?()
    }

    public func installHotPlugListener() {
        guard !listenerInstalled else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let weakSelf: DeviceManager? = self
        let block: @Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>?) -> Void = { _, _ in
            Task { @MainActor in
                weakSelf?.refresh()
            }
        }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            nil,
            block
        )
        listenerInstalled = true
    }

    public func device(withID id: AudioDeviceID) -> AudioDeviceInfo? {
        devices.first { $0.id == id }
    }

    // REQ-004/006: resolve a persisted device UID to the current AudioObjectID.
    public func device(withUID uid: String) -> AudioDeviceInfo? {
        guard !uid.isEmpty else { return nil }
        return devices.first { $0.uid == uid }
    }

    // MARK: - Core Audio access (modern macOS returns raw buffers)

    static func deviceList() -> [AudioDeviceID] {
        let object = AudioObjectID(kAudioObjectSystemObject)
        var size = UInt32(0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioDeviceID>.alignment)
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, buf) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        return Array(UnsafeBufferPointer(start: buf.assumingMemoryBound(to: AudioDeviceID.self), count: count))
    }

    static func channelCount(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var size = UInt32(0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size > 0 else { return 0 }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<AudioBufferList>.size, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buf.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, buf) == noErr else { return 0 }
        var list = buf.assumingMemoryBound(to: AudioBufferList.self).pointee
        let buffers = UnsafeBufferPointer(start: &list.mBuffers, count: Int(list.mNumberBuffers))
        var total = 0
        for buffer in buffers {
            total += Int(buffer.mNumberChannels)
        }
        return total
    }

    // REQ-004/006: stable device identifier (survives coreaudiod restarts).
    static func deviceUID(_ device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? (value as String) : ""
    }

    static func deviceName(_ device: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? (value as String) : "Unknown"
    }
}

// REQ-019/020: device master volume via Core Audio scalar property.
public enum DeviceVolume {
    public static func get(_ device: AudioDeviceID) -> Float? {
        var value = Float(0)
        var size = UInt32(MemoryLayout<Float>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, UnsafeMutableRawPointer(ptr))
        }
        return status == noErr ? value : nil
    }

    public static func set(_ device: AudioDeviceID, _ value: Float) -> Bool {
        var clamped = min(max(value, 0), 1)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &clamped) { ptr -> OSStatus in
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float>.size), UnsafeRawPointer(ptr))
        }
        return status == noErr
    }
}
